// Apply the language before paint; boot-theme.js owns the theme.
// i18n.js replaces this. Boot must still render if that script fails to load.
window.lfT = window.lfT || ((zh) => zh);
(() => {
  const root = document.documentElement;
  let lang = 'zh';
  try {
    lang = localStorage.getItem('zhiyan.lang') === 'en' ? 'en' : 'zh';
  } catch (_) { /* Restricted storage still permits the default interface. */ }
  root.dataset.lang = lang;
  root.lang = lang === 'en' ? 'en' : 'zh-CN';
  try {
    if (sessionStorage.getItem('zhiyan.lang.motion') === 'in') {
      if (matchMedia('(prefers-reduced-motion: reduce)').matches) sessionStorage.removeItem('zhiyan.lang.motion');
      else root.classList.add('lang-enter');
    }
  } catch (_) { /* Enter animation is optional when storage is blocked. */ }
})();
