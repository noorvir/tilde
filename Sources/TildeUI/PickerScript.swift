/// Injected into every page of Tilde's browser. `window.__tilde.inspect(x, y)` returns a
/// JSON string describing the element at a viewport point (fields match `WebElement`,
/// plus `rect`, `color` and `font` for the hover label), or null.
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

  window.__tilde = {
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
        color: style.color,
        font: styles.font,
      });
    },
  };
})();
"""#
