// Чисті функції без DOM: їх перевіряють юніт-тести (node --test).

export function validateBook({ title, author, year }) {
  const clean = {
    title: (title || '').trim(),
    author: (author || '').trim(),
    year: year === '' || year === undefined || year === null ? null : Number(year),
  };
  if (!clean.title) {
    return { error: 'Вкажіть назву книги' };
  }
  if (!clean.author) {
    return { error: 'Вкажіть автора' };
  }
  if (clean.year !== null && (!Number.isInteger(clean.year) || clean.year < 0 || clean.year > 2100)) {
    return { error: 'Рік має бути цілим числом від 0 до 2100' };
  }
  return { book: clean };
}

export function formatBook(book) {
  const year = book.year ? `, ${book.year}` : '';
  return `${book.author}${year}`;
}

export function statusLabel(book) {
  return book.available ? 'В наявності' : 'Видана';
}

export function countAvailable(books) {
  return books.filter((b) => b.available).length;
}
