import { countAvailable, formatBook, statusLabel, validateBook } from './lib.js';

const els = {
  title: document.getElementById('app-title'),
  version: document.getElementById('version'),
  form: document.getElementById('add-form'),
  error: document.getElementById('form-error'),
  search: document.getElementById('search'),
  list: document.getElementById('list'),
  stats: document.getElementById('stats'),
};

async function api(path, options = {}) {
  const resp = await fetch(`/api${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
  });
  if (!resp.ok && resp.status !== 204) {
    const body = await resp.json().catch(() => ({}));
    throw new Error(body.error || `HTTP ${resp.status}`);
  }
  return resp.status === 204 ? null : resp.json();
}

async function loadInfo() {
  try {
    const info = await api('/info');
    els.title.textContent = info.title;
    document.title = info.title;
    els.version.textContent = `v${info.version}`;
  } catch {
    els.version.textContent = 'API недоступне';
  }
}

function button(text, className, onClick) {
  const b = document.createElement('button');
  b.type = 'button';
  b.textContent = text;
  b.className = className;
  b.addEventListener('click', onClick);
  return b;
}

function renderBook(book) {
  const li = document.createElement('li');
  li.className = book.available ? 'book' : 'book book--out';

  const info = document.createElement('div');
  const name = document.createElement('strong');
  name.textContent = book.title;
  const meta = document.createElement('span');
  meta.className = 'meta';
  meta.textContent = formatBook(book);
  info.append(name, meta);

  const status = document.createElement('span');
  status.className = 'status';
  status.textContent = statusLabel(book);

  const actions = document.createElement('div');
  actions.className = 'actions';
  const action = book.available ? 'borrow' : 'return';
  actions.append(
    button(book.available ? 'Видати' : 'Повернути', 'btn', async () => {
      await api(`/books/${book.id}/${action}`, { method: 'POST' });
      load();
    }),
    button('Видалити', 'btn btn--ghost', async () => {
      await api(`/books/${book.id}`, { method: 'DELETE' });
      load();
    }),
  );

  li.append(info, status, actions);
  return li;
}

async function load() {
  const q = els.search.value.trim();
  const books = await api(`/books${q ? `?q=${encodeURIComponent(q)}` : ''}`);
  els.list.replaceChildren(...books.map(renderBook));
  if (books.length === 0) {
    const empty = document.createElement('li');
    empty.className = 'empty';
    empty.textContent = q ? 'Нічого не знайдено' : 'Каталог порожній — додайте першу книгу';
    els.list.append(empty);
  }
  els.stats.textContent = `Книг: ${books.length} · в наявності: ${countAvailable(books)}`;
}

els.form.addEventListener('submit', async (event) => {
  event.preventDefault();
  const data = Object.fromEntries(new FormData(els.form));
  const { book, error } = validateBook(data);
  els.error.textContent = error || '';
  if (error) {
    return;
  }
  try {
    await api('/books', { method: 'POST', body: JSON.stringify(book) });
    els.form.reset();
    load();
  } catch (e) {
    els.error.textContent = e.message;
  }
});

let searchTimer;
els.search.addEventListener('input', () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(load, 250);
});

loadInfo();
load();
