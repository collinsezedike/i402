// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC8004 {
    function isRegistered(address agent) external view returns (bool);
}

interface IX402 {
    function settlePayment(address token, address recipient, uint256 amount) external;
}

contract TaskAuction {
    uint256 public constant MAX_COMPLETION_TIME = 3650 days;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum SelectionRule { LOWEST_PRICE, FASTEST_TIME, WEIGHTED }
    enum TaskStatus   { OPEN, FULFILLING, SETTLED, CANCELLED }

    struct Task {
        address requester;
        bytes32 descriptionHash;
        address paymentToken;
        uint256 maxBudget;
        uint256 bondAmount;
        uint256 biddingDeadline;
        uint256 revealDeadline;
        uint256 fulfillmentDeadline;
        SelectionRule selectionRule;
        uint8 weightPrice;
        uint8 weightTime;
        TaskStatus status;
        address winner;
        uint256 winningPrice;
        bytes32 proofHash;
    }

    struct Commitment {
        bytes32 hash;
        uint256 timestamp;
        bool revealed;
    }

    struct Reveal {
        address agent;
        uint256 price;
        uint256 completionTime;
    }

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    IERC8004 public immutable erc8004;
    IX402    public immutable x402;

    uint256 public taskCount;

    mapping(uint256 => Task)                           public tasks;
    mapping(uint256 => mapping(address => Commitment)) public commitments;
    mapping(uint256 => Reveal[])                       internal reveals;
    mapping(uint256 => uint256)                        public escrow;
    mapping(uint256 => mapping(address => uint256))    public bonds;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event TaskPosted(uint256 indexed taskId, address indexed requester, bytes32 descriptionHash, uint256 maxBudget, uint256 bondAmount);
    event BidCommitted(uint256 indexed taskId, address indexed agent, uint256 commitTimestamp);
    event BidRevealed(uint256 indexed taskId, address indexed agent, uint256 price, uint256 completionTime);
    event WinnerSelected(uint256 indexed taskId, address indexed winner, uint256 price);
    event FulfillmentSubmitted(uint256 indexed taskId, address indexed winner, bytes32 proofHash);
    event TaskSettled(uint256 indexed taskId, address indexed winner, uint256 payment);
    event TaskCancelled(uint256 indexed taskId);
    event BondReturned(uint256 indexed taskId, address indexed agent, uint256 amount);
    event BondForfeited(uint256 indexed taskId, address indexed agent, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotRegistered();
    error TaskNotFound();
    error WrongStatus(TaskStatus expected, TaskStatus actual);
    error BiddingWindowClosed();
    error BiddingWindowOpen();
    error RevealWindowClosed();
    error RevealWindowOpen();
    error FulfillmentWindowClosed();
    error FulfillmentWindowOpen();
    error FulfillmentNotSubmitted();
    error FulfillmentAlreadySubmitted();
    error AlreadyCommitted();
    error AlreadyRevealed();
    error NoBidCommitted();
    error InvalidReveal();
    error InsufficientBond();
    error InsufficientBudget();
    error NotWinner();
    error WinnerCannotClaimBond();
    error NotRequester();
    error InvalidWeights();
    error BondAlreadyClaimed();
    error InvalidDuration();
    error PriceTooHigh();
    error CompletionTimeTooHigh();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _erc8004, address _x402) {
        erc8004 = IERC8004(_erc8004);
        x402    = IX402(_x402);
    }

    // -------------------------------------------------------------------------
    // 1. Post
    // -------------------------------------------------------------------------

    function postTask(
        bytes32       descriptionHash,
        address       paymentToken,
        uint256       maxBudget,
        uint256       bondAmount,
        uint256       biddingDuration,
        uint256       revealDuration,
        uint256       fulfillmentDuration,
        SelectionRule selectionRule,
        uint8         weightPrice,
        uint8         weightTime
    ) external payable returns (uint256 taskId) {
        if (selectionRule == SelectionRule.WEIGHTED && weightPrice + weightTime != 100) revert InvalidWeights();
        if (msg.value < maxBudget || maxBudget == 0) revert InsufficientBudget();
        if (biddingDuration == 0 || revealDuration == 0 || fulfillmentDuration == 0) revert InvalidDuration();

        taskId = ++taskCount;
        escrow[taskId] = msg.value;

        tasks[taskId] = Task({
            requester:           msg.sender,
            descriptionHash:     descriptionHash,
            paymentToken:        paymentToken,
            maxBudget:           maxBudget,
            bondAmount:          bondAmount,
            biddingDeadline:     block.timestamp + biddingDuration,
            revealDeadline:      block.timestamp + biddingDuration + revealDuration,
            fulfillmentDeadline: block.timestamp + biddingDuration + revealDuration + fulfillmentDuration,
            selectionRule:       selectionRule,
            weightPrice:         weightPrice,
            weightTime:          weightTime,
            status:              TaskStatus.OPEN,
            winner:              address(0),
            winningPrice:        0,
            proofHash:           bytes32(0)
        });

        emit TaskPosted(taskId, msg.sender, descriptionHash, maxBudget, bondAmount);
    }

    // -------------------------------------------------------------------------
    // 2. Commit
    // -------------------------------------------------------------------------

    function commitBid(uint256 taskId, bytes32 commitmentHash) external payable {
        Task storage task = _requireTask(taskId);

        if (!erc8004.isRegistered(msg.sender)) revert NotRegistered();
        if (task.status != TaskStatus.OPEN) revert WrongStatus(TaskStatus.OPEN, task.status);
        if (block.timestamp >= task.biddingDeadline) revert BiddingWindowClosed();
        if (commitments[taskId][msg.sender].hash != bytes32(0)) revert AlreadyCommitted();
        if (msg.value < task.bondAmount) revert InsufficientBond();

        bonds[taskId][msg.sender] = msg.value;
        commitments[taskId][msg.sender] = Commitment({
            hash:      commitmentHash,
            timestamp: block.timestamp,
            revealed:  false
        });

        emit BidCommitted(taskId, msg.sender, block.timestamp);
    }

    // -------------------------------------------------------------------------
    // 3. Reveal
    // -------------------------------------------------------------------------

    function revealBid(uint256 taskId, uint256 price, uint256 completionTime, bytes32 nonce) external {
        Task storage task = _requireTask(taskId);
        Commitment storage c = commitments[taskId][msg.sender];

        if (task.status != TaskStatus.OPEN) revert WrongStatus(TaskStatus.OPEN, task.status);
        if (block.timestamp < task.biddingDeadline) revert BiddingWindowOpen();
        if (block.timestamp >= task.revealDeadline) revert RevealWindowClosed();
        if (c.hash == bytes32(0)) revert NoBidCommitted();
        if (c.revealed) revert AlreadyRevealed();
        if (price > task.maxBudget) revert PriceTooHigh();
        if (completionTime > MAX_COMPLETION_TIME) revert CompletionTimeTooHigh();

        bytes32 expected = keccak256(abi.encodePacked(price, completionTime, nonce));
        if (expected != c.hash) revert InvalidReveal();

        c.revealed = true;
        reveals[taskId].push(Reveal({ agent: msg.sender, price: price, completionTime: completionTime }));

        emit BidRevealed(taskId, msg.sender, price, completionTime);
    }

    // -------------------------------------------------------------------------
    // 4. Select
    // -------------------------------------------------------------------------

    function selectWinner(uint256 taskId) external {
        Task storage task = _requireTask(taskId);

        if (task.status != TaskStatus.OPEN) revert WrongStatus(TaskStatus.OPEN, task.status);
        if (block.timestamp < task.revealDeadline) revert RevealWindowOpen();

        Reveal[] storage rv = reveals[taskId];

        if (rv.length == 0) {
            task.status = TaskStatus.CANCELLED;
            _refundRequester(taskId, task.requester);
            emit TaskCancelled(taskId);
            return;
        }

        uint256 bestIndex = _pickWinner(taskId, task, rv);
        Reveal storage winner = rv[bestIndex];

        task.status       = TaskStatus.FULFILLING;
        task.winner       = winner.agent;
        task.winningPrice = winner.price;

        emit WinnerSelected(taskId, winner.agent, winner.price);
    }

    // -------------------------------------------------------------------------
    // 5. Fulfill
    // -------------------------------------------------------------------------

    function submitFulfillment(uint256 taskId, bytes32 proofHash) external {
        Task storage task = _requireTask(taskId);

        if (task.status != TaskStatus.FULFILLING) revert WrongStatus(TaskStatus.FULFILLING, task.status);
        if (msg.sender != task.winner) revert NotWinner();
        if (block.timestamp > task.fulfillmentDeadline) revert FulfillmentWindowClosed();

        task.proofHash = proofHash;
        emit FulfillmentSubmitted(taskId, msg.sender, proofHash);
    }

    // -------------------------------------------------------------------------
    // 6. Settle
    // -------------------------------------------------------------------------

    function confirmAndSettle(uint256 taskId) external {
        Task storage task = _requireTask(taskId);

        if (task.status != TaskStatus.FULFILLING) revert WrongStatus(TaskStatus.FULFILLING, task.status);
        if (msg.sender != task.requester) revert NotRequester();
        if (task.proofHash == bytes32(0)) revert FulfillmentNotSubmitted();

        task.status = TaskStatus.SETTLED;
        uint256 payment = task.winningPrice;
        uint256 escrowed = escrow[taskId];
        escrow[taskId] = 0;

        if (escrowed > payment) {
            payable(task.requester).transfer(escrowed - payment);
        }

        // Always pay winner directly in ETH; notify x402 for accounting if configured
        payable(task.winner).transfer(payment);
        if (address(x402) != address(0)) {
            x402.settlePayment(task.paymentToken, task.winner, payment);
        }

        _returnBond(taskId, task.winner);
        emit TaskSettled(taskId, task.winner, payment);
    }

    // -------------------------------------------------------------------------
    // Bond recovery
    // -------------------------------------------------------------------------

    function claimBond(uint256 taskId) external {
        Task storage task = _requireTask(taskId);

        if (task.status != TaskStatus.FULFILLING && task.status != TaskStatus.SETTLED) {
            revert WrongStatus(TaskStatus.FULFILLING, task.status);
        }
        if (msg.sender == task.winner) revert WinnerCannotClaimBond();
        if (!commitments[taskId][msg.sender].revealed) revert NoBidCommitted();
        if (bonds[taskId][msg.sender] == 0) revert BondAlreadyClaimed();

        _returnBond(taskId, msg.sender);
    }

    function slashWinner(uint256 taskId) external {
        Task storage task = _requireTask(taskId);

        if (task.status != TaskStatus.FULFILLING) revert WrongStatus(TaskStatus.FULFILLING, task.status);
        if (block.timestamp <= task.fulfillmentDeadline) revert FulfillmentWindowOpen();
        if (task.proofHash != bytes32(0)) revert FulfillmentAlreadySubmitted();

        task.status = TaskStatus.CANCELLED;

        uint256 forfeit = bonds[taskId][task.winner];
        bonds[taskId][task.winner] = 0;
        if (forfeit > 0) {
            payable(task.requester).transfer(forfeit);
            emit BondForfeited(taskId, task.winner, forfeit);
        }

        _refundRequester(taskId, task.requester);
        emit TaskCancelled(taskId);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getReveals(uint256 taskId) external view returns (Reveal[] memory) {
        return reveals[taskId];
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _requireTask(uint256 taskId) internal view returns (Task storage task) {
        if (taskId == 0 || taskId > taskCount) revert TaskNotFound();
        task = tasks[taskId];
    }

    function _pickWinner(uint256 taskId, Task storage task, Reveal[] storage rv) internal view returns (uint256 bestIndex) {
        bestIndex = 0;
        for (uint256 i = 1; i < rv.length; i++) {
            if (_isBetter(taskId, task, rv[i], rv[bestIndex])) bestIndex = i;
        }
    }

    function _isBetter(
        uint256 taskId,
        Task storage task,
        Reveal storage a,
        Reveal storage b
    ) internal view returns (bool) {
        SelectionRule rule = task.selectionRule;

        if (rule == SelectionRule.LOWEST_PRICE) {
            if (a.price != b.price) return a.price < b.price;
        } else if (rule == SelectionRule.FASTEST_TIME) {
            if (a.completionTime != b.completionTime) return a.completionTime < b.completionTime;
        } else {
            uint8 wp = task.weightPrice;
            uint8 wt = task.weightTime;
            uint256 scoreA = uint256(wp) * a.price * b.completionTime
                           + uint256(wt) * a.completionTime * b.price;
            uint256 scoreB = uint256(wp) * b.price * a.completionTime
                           + uint256(wt) * b.completionTime * a.price;
            if (scoreA != scoreB) return scoreA < scoreB;
        }

        return commitments[taskId][a.agent].timestamp < commitments[taskId][b.agent].timestamp;
    }

    function _returnBond(uint256 taskId, address agent) internal {
        uint256 amount = bonds[taskId][agent];
        if (amount == 0) return;
        bonds[taskId][agent] = 0;
        payable(agent).transfer(amount);
        emit BondReturned(taskId, agent, amount);
    }

    function _refundRequester(uint256 taskId, address requester) internal {
        uint256 amount = escrow[taskId];
        if (amount == 0) return;
        escrow[taskId] = 0;
        payable(requester).transfer(amount);
    }
}
