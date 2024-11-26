document.addEventListener('DOMContentLoaded', () => {
    const loginButton = document.getElementById('kc-login');
    loginButton.addEventListener('click', handleLogin);
});

function handleLogin(event) {
    event.preventDefault();

    const loginButton = document.getElementById('kc-login');
    loginButton.disabled = true;

    const formData = collectFormData();

    const form = document.getElementById('kc-form-login');
    const actionUrl = form.getAttribute('action');

    sendLoginRequest(actionUrl, formData, loginButton);
}

function collectFormData() {
    const username = document.getElementById('username').value;
    const password = document.getElementById('password').value;
    const credentialId = document.getElementById('id-hidden-input').value;

    const formData = new FormData();
    formData.append('username', username);
    formData.append('password', password);
    formData.append('credentialId', credentialId);

    return formData;
}

function sendLoginRequest(url, data, loginButton) {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', url, true);
    xhr.withCredentials = true;

    xhr.onreadystatechange = () => {
        if (xhr.readyState !== XMLHttpRequest.DONE) return;

        if (xhr.status !== 200) {
            handleError(loginButton);
            return;
        }

        if (xhr.responseURL.includes('protocol/openid-connect/auth')) {
            handleAuthRedirect(xhr.responseText, loginButton);
        } else {
            window.location.href = xhr.responseURL;
        }
    };

    xhr.onerror = () => {
        console.error('Network error.');
        loginButton.disabled = false;
    };

    xhr.send(data);
}

function handleAuthRedirect(responseText, loginButton) {
    const parser = new DOMParser();
    const doc = parser.parseFromString(responseText, 'text/html');

    const fetchedFormAction = doc.querySelector('#kc-form-login')?.action;

    if (fetchedFormAction) {
        const currentForm = document.getElementById('kc-form-login');
        currentForm.action = fetchedFormAction;
        currentForm.method = 'post';
        currentForm.submit();
    } else {
        console.error('Form action not found in the fetched content.');
        loginButton.disabled = false;
    }
}

function handleError(loginButton) {
    // Optional: Display an error message to the user
    console.error('Login failed. Please try again.');
    loginButton.disabled = false;
}
