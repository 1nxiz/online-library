import assert from 'node:assert/strict';
import { test } from 'node:test';

import { countAvailable, formatBook, statusLabel, validateBook } from '../src/lib.js';

test('validateBook приймає коректну книгу', () => {
  const { book, error } = validateBook({ title: ' Кобзар ', author: 'Шевченко', year: '1840' });
  assert.equal(error, undefined);
  assert.deepEqual(book, { title: 'Кобзар', author: 'Шевченко', year: 1840 });
});

test('validateBook дозволяє порожній рік', () => {
  assert.equal(validateBook({ title: 'A', author: 'B', year: '' }).book.year, null);
});

test('validateBook відхиляє порожню назву, автора і поганий рік', () => {
  assert.ok(validateBook({ title: ' ', author: 'B' }).error);
  assert.ok(validateBook({ title: 'A', author: '' }).error);
  assert.ok(validateBook({ title: 'A', author: 'B', year: 'abc' }).error);
  assert.ok(validateBook({ title: 'A', author: 'B', year: '3000' }).error);
});

test('formatBook і statusLabel', () => {
  assert.equal(formatBook({ author: 'Леся Українка', year: 1911 }), 'Леся Українка, 1911');
  assert.equal(formatBook({ author: 'Невідомий', year: null }), 'Невідомий');
  assert.equal(statusLabel({ available: true }), 'В наявності');
  assert.equal(statusLabel({ available: false }), 'Видана');
});

test('countAvailable', () => {
  assert.equal(countAvailable([{ available: true }, { available: false }, { available: true }]), 2);
});
