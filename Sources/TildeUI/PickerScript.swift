/// Injected into every page of Tilde's browser. `window.__tilde.inspect(x, y)` returns a
/// JSON string describing the element at a viewport point (fields match `WebElement`,
/// plus `rect`, scroll, `color` and `font` for the hover label), or null.
/// `window.__tilde.resolve(anchors)` finds annotated elements again, and the page posts
/// "changed" to the `tilde` message handler when they may have moved.
let pickerScript = #"""
(() => {
  if (window.__tilde) return;

  const esc = (value) => (window.CSS && CSS.escape ? CSS.escape(value) : value);
  const usefulClass = (name) => !/[:\[\]\/!@]/.test(name) && !/^(css|sc|jsx|svelte)-/.test(name);

  function selectorFor(element) {
    const parts = [];
    let node = element;
    while (node && node.nodeType === 1 && parts.length < 6) {
      if (node.id) {
        parts.unshift('#' + esc(node.id));
        break;
      }
      let part = node.tagName.toLowerCase();
      const classes = [...node.classList].filter(usefulClass).slice(0, 2);
      if (classes.length) part += '.' + classes.map(esc).join('.');
      const parent = node.parentElement;
      if (parent) {
        const siblings = [...parent.children].filter((child) => child.tagName === node.tagName);
        if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
      }
      parts.unshift(part);
      node = parent;
    }
    return parts.join(' > ');
  }

  function reactInfo(element) {
    const key = Object.keys(element).find((name) => name.startsWith('__reactFiber$') || name.startsWith('__reactInternalInstance$'));
    if (!key) return { components: [], source: null };

    let fiber = element[key];
    let source = null;
    const components = [];
    while (fiber && components.length < 5) {
      if (!source && fiber._debugSource) {
        source = fiber._debugSource.fileName + ':' + fiber._debugSource.lineNumber;
      }
      const type = fiber.type;
      if (type && typeof type !== 'string') {
        const inner = type.render || type.type || type;
        const name = type.displayName || inner.displayName || inner.name;
        if (name && components[0] !== name) components.unshift(name);
      }
      fiber = fiber.return;
    }
    return { components, source };
  }

  function stylesFor(style) {
    const font = style.fontSize + ' ' + style.fontWeight + ' ' + style.fontFamily.split(',')[0].replace(/"/g, '');
    const entries = [
      ['color', style.color],
      ['background', style.backgroundColor],
      ['font', font],
      ['padding', style.padding],
      ['margin', style.margin],
      ['border-radius', style.borderRadius],
      ['display', style.display],
    ];
    return {
      font,
      text: entries
        .filter(([, value]) => value && value !== '0px' && value !== 'rgba(0, 0, 0, 0)')
        .map(([name, value]) => name + ': ' + value)
        .join('; '),
    };
  }

  // Tells Tilde that elements may have moved: on scroll, resize, DOM changes and in-page
  // navigation (pushState, popstate). At most once per frame.
  let notifyQueued = false;
  function notify() {
    if (notifyQueued) return;
    notifyQueued = true;
    requestAnimationFrame(() => {
      notifyQueued = false;
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.tilde;
      if (handler) handler.postMessage('changed');
    });
  }
  addEventListener('scroll', notify, { passive: true, capture: true });
  addEventListener('resize', notify);
  addEventListener('popstate', notify);
  // Back to a page kept in memory: nothing else fires.
  addEventListener('pageshow', notify);
  addEventListener('hashchange', notify);
  for (const name of ['pushState', 'replaceState']) {
    const original = history[name];
    history[name] = function (...args) {
      const result = original.apply(this, args);
      notify();
      return result;
    };
  }
  let mutationTimer = null;
  new MutationObserver(() => {
    clearTimeout(mutationTimer);
    mutationTimer = setTimeout(notify, 150);
  }).observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true });

  const textOf = (element) => (element.innerText || element.textContent || '').trim();

  // The smallest element whose text starts with the snippet, for anchors whose selector broke.
  function findByText(snippet) {
    const needle = snippet.slice(0, 60);
    let best = null;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    for (let node = walker.nextNode(), seen = 0; node && seen < 5000; node = walker.nextNode(), seen++) {
      if (textOf(node).startsWith(needle) && (!best || best.contains(node))) best = node;
    }
    return best;
  }

  const scrolls = (element) => {
    const style = getComputedStyle(element);
    return /(auto|scroll)/.test(style.overflowY + style.overflowX)
      && (element.scrollHeight > element.clientHeight || element.scrollWidth > element.clientWidth);
  };

  // The rect cut to the scrolling panels around the element. Scrolled out of them it has no
  // height: the element is still on the page, but out of view.
  function visibleRect(r, element) {
    let left = r.x, top = r.y, right = r.x + r.width, bottom = r.y + r.height;
    for (let node = element; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
      if (getComputedStyle(node).overflowY === 'visible' && getComputedStyle(node).overflowX === 'visible') continue;
      const clip = node.getBoundingClientRect();
      left = Math.max(left, clip.left);
      top = Math.max(top, clip.top);
      right = Math.min(right, clip.right);
      bottom = Math.min(bottom, clip.bottom);
    }
    return { x: left, y: top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
  }

  window.__tilde = {
    /// Viewport rects for anchors: the selector first (if its text still matches), then the
    /// text, then a region's document rect. null when the element is not on the page.
    resolve(anchors) {
      const result = {};
      for (const anchor of anchors) {
        let element = null;
        if (anchor.selector) {
          try { element = document.querySelector(anchor.selector); } catch (error) { element = null; }
          if (element && anchor.text && !textOf(element).startsWith(anchor.text.slice(0, 60))) element = null;
          if (!element && anchor.text) element = findByText(anchor.text);
        }
        if (element) {
          result[anchor.id] = visibleRect(element.getBoundingClientRect(), element.parentElement);
        } else if (!anchor.selector) {
          const r = anchor.rect;
          let panel = null;
          try { panel = anchor.scroller ? document.querySelector(anchor.scroller) : null; } catch (error) { panel = null; }
          const movedX = panel ? panel.scrollLeft - anchor.scrollerX : 0;
          const movedY = panel ? panel.scrollTop - anchor.scrollerY : 0;
          result[anchor.id] = visibleRect({ x: r.x - scrollX - movedX, y: r.y - scrollY - movedY, width: r.width, height: r.height }, panel);
        } else {
          result[anchor.id] = null;
        }
      }
      return JSON.stringify(result);
    },

    scroll() {
      return [scrollX, scrollY];
    },

    /// The scrolling panel at a point of the viewport, so a region can move with it.
    scroller(x, y) {
      let node = document.elementFromPoint(x, y);
      while (node && node !== document.body && node !== document.documentElement) {
        if (scrolls(node)) return { selector: selectorFor(node), x: node.scrollLeft, y: node.scrollTop };
        node = node.parentElement;
      }
      return null;
    },

    inspect(x, y) {
      const element = document.elementFromPoint(x, y);
      if (!element) return null;

      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      const styles = stylesFor(style);
      const react = reactInfo(element);
      const html = element.outerHTML;

      return JSON.stringify({
        url: location.href,
        title: document.title,
        tag: element.tagName.toLowerCase(),
        selector: selectorFor(element),
        text: (element.innerText || element.textContent || '').trim().slice(0, 200),
        html: html.length > 2000 ? html.slice(0, 2000) + '\n<!-- truncated -->' : html,
        components: react.components,
        source: react.source,
        styles: styles.text,
        rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
        scrollX: scrollX,
        scrollY: scrollY,
        color: style.color,
        font: styles.font,
      });
    },
  };
})();
"""#
