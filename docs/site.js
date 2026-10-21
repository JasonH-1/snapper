// The landing page: the hero clip, the collection tabs and the before/after
// photos. Without JavaScript the clip shows its poster and every collection
// is listed one after another.

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

// The hero clip plays unless the visitor asked for less motion, and can
// always be paused.
const video = document.querySelector('.screen video');
const play = document.querySelector('.screen .play');
if (video && play) {
  const sync = () => {
    play.dataset.state = video.paused ? 'paused' : 'playing';
    play.setAttribute('aria-label', video.paused ? 'Play video' : 'Pause video');
  };
  play.hidden = false;
  play.addEventListener('click', () => (video.paused ? video.play() : video.pause()));
  video.addEventListener('play', sync);
  video.addEventListener('pause', sync);
  sync();
  if (!reduceMotion.matches) video.play().catch(sync);
}

// Collection tabs.
const tabs = [...document.querySelectorAll('[role="tab"]')];
const panels = tabs.map((tab) => document.getElementById(tab.getAttribute('aria-controls')));

function select(index, { focus = false } = {}) {
  tabs.forEach((tab, i) => {
    const selected = i === index;
    tab.setAttribute('aria-selected', String(selected));
    tab.tabIndex = selected ? 0 : -1;
    panels[i].classList.toggle('active', selected);
  });
  if (focus) tabs[index].focus();
  tabs[index].scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: reduceMotion.matches ? 'auto' : 'smooth' });
}

tabs.forEach((tab, i) => {
  tab.addEventListener('click', () => select(i));
  tab.addEventListener('keydown', (event) => {
    const next = { ArrowRight: i + 1, ArrowLeft: i - 1, Home: 0, End: tabs.length - 1 }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    select((next + tabs.length) % tabs.length, { focus: true });
  });
});

// Before/after: drag or tap across the photo, or use the arrow keys on its
// slider. Vertical swipes still scroll the page.
for (const compare of document.querySelectorAll('.compare')) {
  const range = compare.querySelector('input[type="range"]');
  const set = (percent) => {
    compare.style.setProperty('--split', `${percent}%`);
    range.value = percent;
    // A label the divider has reached would sit on the other photo.
    compare.classList.toggle('near-left', percent < 24);
    compare.classList.toggle('near-right', percent > 76);
  };
  const follow = (event) => {
    const box = compare.getBoundingClientRect();
    set(Math.round(Math.min(Math.max((event.clientX - box.left) / box.width, 0), 1) * 1000) / 10);
  };
  range.addEventListener('input', () => set(range.value));
  compare.addEventListener('pointerdown', (event) => {
    compare.setPointerCapture(event.pointerId);
    if (event.pointerType === 'mouse') follow(event);
  });
  compare.addEventListener('pointermove', (event) => {
    if (compare.hasPointerCapture(event.pointerId)) follow(event);
  });
  compare.addEventListener('click', follow);
}
