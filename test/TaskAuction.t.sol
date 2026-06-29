// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/TaskAuction.sol";

// ---------------------------------------------------------------------------
// Minimal stubs
// ---------------------------------------------------------------------------

contract MockERC8004 is IERC8004 {
    mapping(address => bool) private _registered;

    function register(address agent) external { _registered[agent] = true; }
    function isRegistered(address agent) external view returns (bool) { return _registered[agent]; }
}

contract MockX402 is IX402 {
    address public lastRecipient;
    uint256 public lastAmount;

    function settlePayment(address, address recipient, uint256 amount) external {
        lastRecipient = recipient;
        lastAmount    = amount;
        // In tests the auction holds native ETH, so we just record the call.
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

contract TaskAuctionTest is Test {
    TaskAuction auction;
    MockERC8004 registry;
    MockX402    x402;

    address requester = makeAddr("requester");
    address agentA    = makeAddr("agentA");
    address agentB    = makeAddr("agentB");
    address agentC    = makeAddr("agentC");

    uint256 constant BOND      = 0.01 ether;
    uint256 constant BUDGET    = 1 ether;
    uint256 constant BID_WIN   = 300;  // seconds
    uint256 constant REVEAL_WIN = 300;
    uint256 constant FULFILL_WIN = 600;

    function setUp() public {
        registry = new MockERC8004();
        x402     = new MockX402();
        auction  = new TaskAuction(address(registry), address(x402));

        registry.register(agentA);
        registry.register(agentB);
        registry.register(agentC);

        vm.deal(requester, 10 ether);
        vm.deal(agentA,    1 ether);
        vm.deal(agentB,    1 ether);
        vm.deal(agentC,    1 ether);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _postTask(TaskAuction.SelectionRule rule) internal returns (uint256) {
        vm.prank(requester);
        return auction.postTask{value: BUDGET}(
            keccak256("task description"),
            address(0),
            BUDGET,
            BOND,
            BID_WIN,
            REVEAL_WIN,
            FULFILL_WIN,
            rule,
            50, // weightPrice
            50  // weightTime
        );
    }

    function _commitment(uint256 price, uint256 time, bytes32 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(price, time, nonce));
    }

    // -----------------------------------------------------------------------
    // Post task
    // -----------------------------------------------------------------------

    function test_PostTask_StoresTask() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        assertEq(id, 1);

        (
            address req,,,,,,,,,,,
            TaskAuction.TaskStatus status,,
        ) = auction.tasks(id);

        assertEq(req, requester);
        assertEq(uint8(status), uint8(TaskAuction.TaskStatus.OPEN));
        assertEq(auction.escrow(id), BUDGET);
    }

    function test_PostTask_RevertsInsufficientBudget() public {
        vm.prank(requester);
        vm.expectRevert(TaskAuction.InsufficientBudget.selector);
        auction.postTask{value: BUDGET - 1}(
            keccak256("x"),
            address(0),
            BUDGET,
            BOND,
            BID_WIN,
            REVEAL_WIN,
            FULFILL_WIN,
            TaskAuction.SelectionRule.LOWEST_PRICE,
            0, 0
        );
    }

    function test_PostTask_InvalidWeightsReverts() public {
        vm.prank(requester);
        vm.expectRevert(TaskAuction.InvalidWeights.selector);
        auction.postTask{value: BUDGET}(
            keccak256("x"),
            address(0),
            BUDGET,
            BOND,
            BID_WIN,
            REVEAL_WIN,
            FULFILL_WIN,
            TaskAuction.SelectionRule.WEIGHTED,
            40, 40 // does not sum to 100
        );
    }

    // -----------------------------------------------------------------------
    // Commit
    // -----------------------------------------------------------------------

    function test_Commit_Succeeds() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        bytes32 h  = _commitment(0.5 ether, 3600, bytes32(uint256(1)));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, h);

        (bytes32 storedHash,, bool revealed) = auction.commitments(id, agentA);
        assertEq(storedHash, h);
        assertFalse(revealed);
    }

    function test_Commit_RevertsUnregistered() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        address unknown = makeAddr("unknown");
        vm.deal(unknown, 1 ether);

        vm.prank(unknown);
        vm.expectRevert(TaskAuction.NotRegistered.selector);
        auction.commitBid{value: BOND}(id, bytes32(uint256(1)));
    }

    function test_Commit_RevertsAfterBiddingDeadline() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        skip(BID_WIN + 1);

        vm.prank(agentA);
        vm.expectRevert(TaskAuction.BiddingWindowClosed.selector);
        auction.commitBid{value: BOND}(id, bytes32(uint256(1)));
    }

    function test_Commit_RevertsDoubleCommit() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        bytes32 h  = _commitment(0.5 ether, 3600, bytes32(uint256(1)));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, h);

        vm.prank(agentA);
        vm.expectRevert(TaskAuction.AlreadyCommitted.selector);
        auction.commitBid{value: BOND}(id, h);
    }

    function test_Commit_RevertsInsufficientBond() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);

        vm.prank(agentA);
        vm.expectRevert(TaskAuction.InsufficientBond.selector);
        auction.commitBid{value: BOND - 1}(id, bytes32(uint256(1)));
    }

    // -----------------------------------------------------------------------
    // Reveal
    // -----------------------------------------------------------------------

    function test_Reveal_Succeeds() public {
        uint256 id     = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        uint256 price  = 0.5 ether;
        uint256 time   = 3600;
        bytes32 nonce  = bytes32(uint256(42));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(price, time, nonce));

        skip(BID_WIN + 1);

        vm.prank(agentA);
        auction.revealBid(id, price, time, nonce);

        assertEq(auction.getRevealCount(id), 1);
    }

    function test_Reveal_RevertsInvalidHash() public {
        uint256 id    = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        bytes32 nonce = bytes32(uint256(42));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(0.5 ether, 3600, nonce));

        skip(BID_WIN + 1);

        vm.prank(agentA);
        vm.expectRevert(TaskAuction.InvalidReveal.selector);
        auction.revealBid(id, 0.6 ether, 3600, nonce); // wrong price
    }

    function test_Reveal_RevertsBeforeBiddingClose() public {
        uint256 id    = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        bytes32 nonce = bytes32(uint256(1));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(0.5 ether, 3600, nonce));

        // Still in bidding window
        vm.prank(agentA);
        vm.expectRevert(TaskAuction.BiddingWindowOpen.selector);
        auction.revealBid(id, 0.5 ether, 3600, nonce);
    }

    function test_Reveal_RevertsAfterRevealDeadline() public {
        uint256 id    = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);
        bytes32 nonce = bytes32(uint256(1));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(0.5 ether, 3600, nonce));

        skip(BID_WIN + REVEAL_WIN + 1);

        vm.prank(agentA);
        vm.expectRevert(TaskAuction.RevealWindowClosed.selector);
        auction.revealBid(id, 0.5 ether, 3600, nonce);
    }

    // -----------------------------------------------------------------------
    // Selection - lowest price
    // -----------------------------------------------------------------------

    function test_SelectWinner_LowestPrice() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);

        bytes32 nonceA = bytes32(uint256(1));
        bytes32 nonceB = bytes32(uint256(2));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(0.7 ether, 3600, nonceA));

        vm.prank(agentB);
        auction.commitBid{value: BOND}(id, _commitment(0.4 ether, 3600, nonceB));

        skip(BID_WIN + 1);

        vm.prank(agentA);
        auction.revealBid(id, 0.7 ether, 3600, nonceA);

        vm.prank(agentB);
        auction.revealBid(id, 0.4 ether, 3600, nonceB);

        skip(REVEAL_WIN + 1);
        auction.selectWinner(id);

        (,,,,,,,,,,, TaskAuction.TaskStatus status, address winner,) = auction.tasks(id);
        assertEq(winner, agentB);
        assertEq(uint8(status), uint8(TaskAuction.TaskStatus.FULFILLING));
    }

    function test_SelectWinner_FastestTime() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.FASTEST_TIME);

        bytes32 nonceA = bytes32(uint256(1));
        bytes32 nonceB = bytes32(uint256(2));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(0.5 ether, 7200, nonceA));

        vm.prank(agentB);
        auction.commitBid{value: BOND}(id, _commitment(0.5 ether, 1800, nonceB));

        skip(BID_WIN + 1);

        vm.prank(agentA);
        auction.revealBid(id, 0.5 ether, 7200, nonceA);

        vm.prank(agentB);
        auction.revealBid(id, 0.5 ether, 1800, nonceB);

        skip(REVEAL_WIN + 1);
        auction.selectWinner(id);

        (,,,,,,,,,,, , address winner,) = auction.tasks(id);
        assertEq(winner, agentB);
    }

    function test_SelectWinner_TiebreakByCommitTimestamp() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);

        bytes32 nonceA = bytes32(uint256(1));
        bytes32 nonceB = bytes32(uint256(2));
        uint256 samePrice = 0.5 ether;

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(samePrice, 3600, nonceA));

        skip(10); // agentB commits later

        vm.prank(agentB);
        auction.commitBid{value: BOND}(id, _commitment(samePrice, 3600, nonceB));

        skip(BID_WIN);

        vm.prank(agentA);
        auction.revealBid(id, samePrice, 3600, nonceA);

        vm.prank(agentB);
        auction.revealBid(id, samePrice, 3600, nonceB);

        skip(REVEAL_WIN + 1);
        auction.selectWinner(id);

        (,,,,,,,,,,, , address winner,) = auction.tasks(id);
        assertEq(winner, agentA); // earlier commit wins the tie
    }

    function test_SelectWinner_NoReveals_Cancels() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);

        // agentA commits but never reveals
        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, bytes32(uint256(999)));

        skip(BID_WIN + REVEAL_WIN + 1);

        uint256 before = requester.balance;
        auction.selectWinner(id);
        uint256 after_ = requester.balance;

        (,,,,,,,,,,, TaskAuction.TaskStatus status,,) = auction.tasks(id);
        assertEq(uint8(status), uint8(TaskAuction.TaskStatus.CANCELLED));
        assertEq(after_ - before, BUDGET); // requester refunded
    }

    // -----------------------------------------------------------------------
    // Fulfillment & settlement
    // -----------------------------------------------------------------------

    function _runToFulfilling(TaskAuction.SelectionRule rule) internal returns (uint256 id, uint256 price) {
        id    = _postTask(rule);
        price = 0.5 ether;

        bytes32 nonce = bytes32(uint256(7));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(price, 3600, nonce));

        skip(BID_WIN + 1);

        vm.prank(agentA);
        auction.revealBid(id, price, 3600, nonce);

        skip(REVEAL_WIN + 1);
        auction.selectWinner(id);
    }

    function test_SubmitFulfillment_Succeeds() public {
        (uint256 id,) = _runToFulfilling(TaskAuction.SelectionRule.LOWEST_PRICE);

        vm.prank(agentA);
        auction.submitFulfillment(id, keccak256("proof"));
    }

    function test_SubmitFulfillment_RevertsNonWinner() public {
        (uint256 id,) = _runToFulfilling(TaskAuction.SelectionRule.LOWEST_PRICE);

        vm.prank(agentB);
        vm.expectRevert(TaskAuction.NotWinner.selector);
        auction.submitFulfillment(id, keccak256("proof"));
    }

    function test_ConfirmAndSettle_PaymentsCorrect() public {
        (uint256 id, uint256 price) = _runToFulfilling(TaskAuction.SelectionRule.LOWEST_PRICE);

        vm.prank(agentA);
        auction.submitFulfillment(id, keccak256("proof"));

        uint256 requesterBefore = requester.balance;
        uint256 agentBefore     = agentA.balance;

        vm.prank(requester);
        auction.confirmAndSettle(id);

        // agentA gets price paid + bond back (via direct transfer since x402 is mocked to no-op)
        // Since x402 mock doesn't actually send ETH, we just check escrow drained and bond returned.
        assertEq(auction.escrow(id), 0);

        // Requester should get back overage: BUDGET - price
        assertApproxEqAbs(requester.balance, requesterBefore + (BUDGET - price), 1);
        // agentA bond returned
        assertEq(agentA.balance, agentBefore + BOND);
    }

    function test_ConfirmAndSettle_RevertsNonRequester() public {
        (uint256 id,) = _runToFulfilling(TaskAuction.SelectionRule.LOWEST_PRICE);

        vm.prank(agentA);
        auction.submitFulfillment(id, keccak256("proof"));

        vm.prank(agentB);
        vm.expectRevert(TaskAuction.NotRequester.selector);
        auction.confirmAndSettle(id);
    }

    // -----------------------------------------------------------------------
    // Bond mechanics
    // -----------------------------------------------------------------------

    function test_LoosingAgents_CanClaimBond() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);

        bytes32 nonceA = bytes32(uint256(1));
        bytes32 nonceB = bytes32(uint256(2));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(0.3 ether, 3600, nonceA)); // wins

        vm.prank(agentB);
        auction.commitBid{value: BOND}(id, _commitment(0.5 ether, 3600, nonceB)); // loses

        skip(BID_WIN + 1);

        vm.prank(agentA);
        auction.revealBid(id, 0.3 ether, 3600, nonceA);

        vm.prank(agentB);
        auction.revealBid(id, 0.5 ether, 3600, nonceB);

        skip(REVEAL_WIN + 1);
        auction.selectWinner(id);

        uint256 before = agentB.balance;
        vm.prank(agentB);
        auction.claimBond(id);
        assertEq(agentB.balance, before + BOND);
    }

    function test_NonRevealingAgent_CannotClaimBond() public {
        uint256 id = _postTask(TaskAuction.SelectionRule.LOWEST_PRICE);

        bytes32 nonceA = bytes32(uint256(1));

        vm.prank(agentA);
        auction.commitBid{value: BOND}(id, _commitment(0.5 ether, 3600, nonceA)); // wins

        vm.prank(agentB);
        auction.commitBid{value: BOND}(id, bytes32(uint256(999))); // commits but never reveals

        skip(BID_WIN + 1);

        vm.prank(agentA);
        auction.revealBid(id, 0.5 ether, 3600, nonceA);

        skip(REVEAL_WIN + 1);
        auction.selectWinner(id);

        vm.prank(agentB);
        vm.expectRevert(TaskAuction.NoBidCommitted.selector);
        auction.claimBond(id);
    }

    function test_SlashWinner_ForfeitsBondAndRefunds() public {
        (uint256 id,) = _runToFulfilling(TaskAuction.SelectionRule.LOWEST_PRICE);

        // Let fulfillment window expire without submitting proof
        skip(FULFILL_WIN + 1);

        uint256 requesterBefore = requester.balance;
        auction.slashWinner(id);

        (,,,,,,,,,,, TaskAuction.TaskStatus status,,) = auction.tasks(id);
        assertEq(uint8(status), uint8(TaskAuction.TaskStatus.CANCELLED));

        // Requester got escrow back + winner's forfeited bond
        assertGt(requester.balance, requesterBefore);
        assertEq(auction.escrow(id), 0);
    }
}
