// Scroll-reveal: fires once per element
const revealObserver = new IntersectionObserver(
  (entries) => entries.forEach((e) => {
    if (e.isIntersecting) {
      e.target.classList.add('is-visible');
      revealObserver.unobserve(e.target);
    }
  }),
  { threshold: 0.12 }
);

document.querySelectorAll('.reveal').forEach((el) => revealObserver.observe(el));

// Stagger cards and steps within their parent when parent becomes visible
const staggerObserver = new IntersectionObserver(
  (entries) => entries.forEach((e) => {
    if (e.isIntersecting) {
      const children = e.target.querySelectorAll('.reveal');
      children.forEach((child, i) => {
        setTimeout(() => child.classList.add('is-visible'), i * 120);
      });
      staggerObserver.unobserve(e.target);
    }
  }),
  { threshold: 0.08 }
);

document.querySelectorAll('.steps, .cards').forEach((el) => staggerObserver.observe(el));

// Nav: add scrolled class for backdrop
const nav = document.querySelector('.nav');
const onScroll = () => nav.classList.toggle('nav--scrolled', window.scrollY > 40);
window.addEventListener('scroll', onScroll, { passive: true });
onScroll();
