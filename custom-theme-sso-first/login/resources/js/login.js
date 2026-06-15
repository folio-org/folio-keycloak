const IS_CONSORTIUM_KEY = 'isConsortium';
const urlParams = new URLSearchParams(window.location.search);
const isConsortium = urlParams.get(IS_CONSORTIUM_KEY);
const clientId = urlParams.get('client_id');

if (isConsortium === 'true' || sessionStorage.getItem(IS_CONSORTIUM_KEY) === 'true') {
  // Persist this param value since it gets cleared on form submit.
  // Session storage ensures other tabs or future browser sessions don't retain value.
  sessionStorage.setItem(IS_CONSORTIUM_KEY, 'true');
  document.getElementById('return-to-tenant-selection').style.display = 'block';
}
