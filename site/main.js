(() => {
  "use strict";

  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const revealItems = document.querySelectorAll(".reveal");

  if ("IntersectionObserver" in window && !reducedMotion.matches) {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    }, { threshold: 0.08 });

    revealItems.forEach((item) => {
      item.classList.add("will-reveal");
      observer.observe(item);
    });
  }

  const demo = document.querySelector("[data-demo]");
  const slides = [...demo.querySelectorAll("[data-slide]")];
  const options = [...demo.querySelectorAll("[data-preview]")];
  const playback = demo.querySelector(".demo-playback");
  const playbackIcon = demo.querySelector("[data-playback-icon]");
  let active = 0;
  let paused = reducedMotion.matches;
  let inView = true;
  let timer;

  function showSlide(index) {
    active = index;
    slides.forEach((slide, i) => {
      slide.hidden = i !== index;
      slide.classList.toggle("is-active", i === index);
      options[i].setAttribute("aria-pressed", String(i === index));
    });
  }

  function updatePlayback() {
    window.clearInterval(timer);
    playback.setAttribute("aria-label", paused ? "Play preview" : "Pause preview");
    playbackIcon.textContent = paused ? "▶" : "Ⅱ";
    if (!paused && inView && !document.hidden) {
      timer = window.setInterval(() => showSlide((active + 1) % slides.length), 5000);
    }
  }

  options.forEach((option, index) => {
    option.addEventListener("click", () => {
      paused = true;
      showSlide(index);
      updatePlayback();
    });
  });

  playback.addEventListener("click", () => {
    paused = !paused;
    updatePlayback();
  });

  reducedMotion.addEventListener("change", (event) => {
    if (!event.matches) return;
    paused = true;
    revealItems.forEach((item) => item.classList.add("is-visible"));
    updatePlayback();
  });

  if ("IntersectionObserver" in window) {
    const demoObserver = new IntersectionObserver(([entry]) => {
      inView = entry.isIntersecting;
      updatePlayback();
    });
    demoObserver.observe(demo);
  }

  document.addEventListener("visibilitychange", updatePlayback);
  demo.querySelector(".demo-controls").hidden = false;
  updatePlayback();

  function openLinkedQuestion() {
    if (window.location.hash !== "#faq-open") return;
    document.getElementById("faq-open").open = true;
  }

  document.querySelector(".first-open").addEventListener("click", () => {
    document.getElementById("faq-open").open = true;
  });
  window.addEventListener("hashchange", openLinkedQuestion);
  openLinkedQuestion();
})();

document.querySelectorAll('.install-copy').forEach((button) => {
  button.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(button.dataset.copy); button.textContent = 'Copied'; }
    catch { button.textContent = 'Select it'; }
    setTimeout(() => { button.textContent = 'Copy'; }, 1600);
  });
});
