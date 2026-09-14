/* AI Migration Kit site script: scheme toggle, copy buttons, on-page contents, the hasp release,
   the mobile navigation. Everything here is an enhancement: the page reads and installs without it. */
(function () {
  'use strict';

  var root = document.documentElement;

  /* Scheme toggle: flips data-kit-scheme, remembers it, keeps aria-pressed honest. */
  function currentDark() {
    var set = root.getAttribute('data-kit-scheme');
    if (set === 'dark') return true;
    if (set === 'light') return false;
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }
  var toggles = document.querySelectorAll('.kit-scheme-toggle');
  function paint() {
    var dark = currentDark();
    for (var i = 0; i < toggles.length; i++) toggles[i].setAttribute('aria-pressed', dark ? 'true' : 'false');
  }
  paint();
  for (var t = 0; t < toggles.length; t++) {
    toggles[t].addEventListener('click', function () {
      var next = currentDark() ? 'light' : 'dark';
      root.setAttribute('data-kit-scheme', next);
      try { localStorage.setItem('kit-scheme', next); } catch (e) { /* private mode: not remembered */ }
      paint();
    });
  }
  if (window.matchMedia) {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', paint);
  }

  /* Copy buttons on every code block. */
  var blocks = document.querySelectorAll('div.highlighter-rouge, .kit-body > pre:not(.mermaid)');
  for (var b = 0; b < blocks.length; b++) {
    (function (block) {
      var code = block.querySelector('code') || block;
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'kit-chip kit-copy';
      btn.textContent = 'Copy';
      btn.setAttribute('aria-label', 'Copy to clipboard');
      btn.addEventListener('click', function () {
        var text = code.textContent.replace(/\n$/, '');
        var done = function () {
          btn.textContent = 'Copied';
          btn.classList.add('is-done');
          setTimeout(function () { btn.textContent = 'Copy'; btn.classList.remove('is-done'); }, 1600);
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(done, function () { fallback(text); done(); });
        } else {
          fallback(text); done();
        }
      });
      block.appendChild(btn);
    })(blocks[b]);
  }
  function fallback(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.top = '-1000px';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) { /* nothing to do */ }
    document.body.removeChild(ta);
  }

  /* On-page contents from the article's h2s, with the current one marked while scrolling. */
  var toc = document.querySelector('.kit-toc');
  var article = document.querySelector('.kit-article .kit-body');
  if (toc && article) {
    var heads = article.querySelectorAll('h2[id]');
    if (heads.length > 1) {
      var title = document.createElement('p');
      title.className = 'kit-toc-title';
      title.textContent = 'On this page';
      var list = document.createElement('ol');
      var links = [];
      for (var h = 0; h < heads.length; h++) {
        var li = document.createElement('li');
        var a = document.createElement('a');
        a.href = '#' + heads[h].id;
        a.textContent = heads[h].textContent.replace(/\s*#?\s*$/, '');
        li.appendChild(a);
        list.appendChild(li);
        links.push(a);
      }
      toc.appendChild(title);
      toc.appendChild(list);
      if ('IntersectionObserver' in window) {
        var active = null;
        var io = new IntersectionObserver(function (entries) {
          for (var e = 0; e < entries.length; e++) {
            if (entries[e].isIntersecting) {
              var id = entries[e].target.id;
              for (var l = 0; l < links.length; l++) {
                var on = links[l].getAttribute('href') === '#' + id;
                links[l].classList.toggle('is-active', on);
              }
              active = id;
            }
          }
        }, { rootMargin: '-80px 0px -70% 0px', threshold: 0 });
        for (var k = 0; k < heads.length; k++) io.observe(heads[k]);
      }
    }
  }

  /* The hasp: the seven locks release once, left to right, on the home page. */
  var hasp = document.querySelector('.kit-hasp');
  if (hasp) {
    var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var locks = hasp.querySelectorAll('.kit-lock');
    if (reduce) {
      hasp.classList.add('is-released');
    } else {
      var start = function () {
        for (var i = 0; i < locks.length; i++) {
          (function (lock, i) {
            setTimeout(function () { lock.classList.add('is-open'); }, 350 + i * 140);
          })(locks[i], i);
        }
      };
      if ('IntersectionObserver' in window) {
        var once = new IntersectionObserver(function (entries) {
          if (entries[0].isIntersecting) { start(); once.disconnect(); }
        }, { threshold: 0.15 });
        once.observe(hasp);
      } else {
        start();
      }
    }
  }

  /* Mobile navigation: the documentation list folds under a button below 60rem. */
  var navToggle = document.querySelector('.kit-sidenav-toggle');
  if (navToggle) {
    navToggle.addEventListener('click', function () {
      var open = navToggle.getAttribute('aria-expanded') === 'true';
      navToggle.setAttribute('aria-expanded', open ? 'false' : 'true');
    });
    if (location.hash === '#site-nav') navToggle.setAttribute('aria-expanded', 'true');
    window.addEventListener('hashchange', function () {
      if (location.hash === '#site-nav') navToggle.setAttribute('aria-expanded', 'true');
    });
  }
})();
