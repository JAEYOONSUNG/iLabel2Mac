(() => {
  'use strict';

  const root = document.documentElement;
  const korean = root.lang === 'ko';
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const motionButton = document.querySelector('.motion-toggle');
  const demoButton = document.querySelector('.demo-toggle');
  const demoImage = document.querySelector('#workflow-demo');
  const artwork = document.querySelector('.hero-art');
  const progress = document.querySelector('.scroll-progress');
  let motionEnabled = true;
  let artworkVisible = true;
  let demoPlaying = false;

  function setButton(button, icon, label) {
    button.querySelector('use').setAttribute('href', `#icon-${icon}`);
    button.querySelector('span').textContent = label;
  }

  function syncMotion() {
    root.dataset.motion = motionEnabled && !reducedMotion.matches && artworkVisible && !document.hidden
      ? 'running' : 'paused';
    motionButton.hidden = reducedMotion.matches;
    setButton(motionButton, motionEnabled ? 'pause' : 'play', korean
      ? (motionEnabled ? '모션 정지' : '모션 재생')
      : (motionEnabled ? 'Pause motion' : 'Play motion'));
  }

  motionButton.addEventListener('click', () => {
    motionEnabled = !motionEnabled;
    syncMotion();
  });

  function setDemo(playing) {
    demoPlaying = playing;
    demoImage.src = playing ? demoImage.dataset.animation : demoImage.dataset.poster;
    demoButton.setAttribute('aria-pressed', String(playing));
    setButton(demoButton, playing ? 'pause' : 'play', korean
      ? (playing ? '시연 정지' : '시연 재생')
      : (playing ? 'Stop walkthrough' : 'Play walkthrough'));
  }

  demoButton.hidden = false;
  demoButton.addEventListener('click', () => setDemo(!demoPlaying));
  demoImage.addEventListener('error', () => {
    if (!demoPlaying) return;
    setDemo(false);
    demoButton.querySelector('span').textContent = korean ? '시연 다시 시도' : 'Retry walkthrough';
  });

  // The GIF is an explicit opt-in. Stop loading frames when it leaves the viewport.
  if ('IntersectionObserver' in window) {
    const visibilityObserver = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (entry.target === artwork) {
          artworkVisible = entry.isIntersecting;
          syncMotion();
        } else if (!entry.isIntersecting && demoPlaying) {
          setDemo(false);
        }
      }
    }, { threshold: 0 });
    visibilityObserver.observe(artwork);
    visibilityObserver.observe(demoImage);
  }

  const reveals = document.querySelectorAll('.hero-copy, .hero-art, .hero-shot, .statement p, section > h2, section > .lede, .card, .split, .band, .tier, .faq, .final');
  if ('IntersectionObserver' in window && !reducedMotion.matches) {
    const revealObserver = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.remove('is-pending');
        revealObserver.unobserve(entry.target);
      }
    }, { threshold: 0.08 });

    reveals.forEach(element => {
      element.classList.add('reveal');
      // Entrances should never hide content already being read, linked, or focused.
      if (element.getBoundingClientRect().top > window.innerHeight * 0.94) {
        element.classList.add('is-pending');
        if (element.matches('.card, .tier') && window.innerWidth > 760) {
          const siblings = [...element.parentElement.children];
          element.style.setProperty('--reveal-delay', `${siblings.indexOf(element) * 90}ms`);
        }
        revealObserver.observe(element);
      }
    });
    document.addEventListener('focusin', event => {
      event.target.closest('.is-pending')?.classList.remove('is-pending');
    });
  }

  reducedMotion.addEventListener('change', () => {
    if (reducedMotion.matches) {
      reveals.forEach(element => element.classList.remove('is-pending'));
      if (demoPlaying) setDemo(false);
    }
    syncMotion();
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden && demoPlaying) setDemo(false);
    syncMotion();
  });

  let progressFrame = 0;
  function updateProgress() {
    const distance = root.scrollHeight - window.innerHeight;
    const fraction = distance > 0 ? Math.min(1, Math.max(0, window.scrollY / distance)) : 0;
    progress.style.transform = `scaleX(${fraction})`;
    progressFrame = 0;
  }
  function requestProgress() {
    if (!progressFrame) progressFrame = requestAnimationFrame(updateProgress);
  }
  window.addEventListener('scroll', requestProgress, { passive: true });
  window.addEventListener('resize', requestProgress, { passive: true });
  syncMotion();
  updateProgress();
})();
