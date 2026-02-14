import { describe, it, expect, beforeEach, vi } from 'vitest';
import { domManipulator } from './domManipulator';
import { CSS_CLASSES, DATA_ATTRIBUTES } from '../shared/constants';

describe('domManipulator', () => {
  beforeEach(() => {
    document.body.innerHTML = '';
  });

  it('collapses tweet using data attribute and prepended placeholder', () => {
    const article = document.createElement('article');
    const content = document.createElement('div');
    content.textContent = 'tweet content';
    article.appendChild(content);
    document.body.appendChild(article);

    domManipulator.collapseTweet(article);

    expect(article.dataset[DATA_ATTRIBUTES.COLLAPSED]).toBe('true');
    expect(article.firstElementChild).not.toBeNull();
    expect(article.firstElementChild?.classList.contains(CSS_CLASSES.PLACEHOLDER)).toBe(true);
  });

  it('does not add duplicate placeholder when collapse is called twice', () => {
    const article = document.createElement('article');
    article.appendChild(document.createElement('div'));
    document.body.appendChild(article);

    domManipulator.collapseTweet(article);
    domManipulator.collapseTweet(article);

    const placeholders = article.querySelectorAll(`.${CSS_CLASSES.PLACEHOLDER}`);
    expect(placeholders).toHaveLength(1);
  });

  it('expands tweet by removing placeholder and collapsed data attribute', () => {
    const article = document.createElement('article');
    article.appendChild(document.createElement('div'));
    document.body.appendChild(article);

    domManipulator.collapseTweet(article);
    domManipulator.expandTweet(article);

    expect(article.querySelector(`.${CSS_CLASSES.PLACEHOLDER}`)).toBeNull();
    expect(article.dataset[DATA_ATTRIBUTES.COLLAPSED]).toBeUndefined();
  });

  it('expand button click expands tweet and does not bubble click event', () => {
    const article = document.createElement('article');
    article.appendChild(document.createElement('div'));
    document.body.appendChild(article);

    const parentClick = vi.fn();
    article.addEventListener('click', parentClick);

    domManipulator.collapseTweet(article);
    const button = article.querySelector<HTMLButtonElement>('.tweet-filter-expand-btn');
    expect(button).not.toBeNull();

    button?.click();

    expect(article.querySelector(`.${CSS_CLASSES.PLACEHOLDER}`)).toBeNull();
    expect(article.dataset[DATA_ATTRIBUTES.COLLAPSED]).toBeUndefined();
    expect(parentClick).not.toHaveBeenCalled();
  });

  it('marks processed tweet and reports processed state', () => {
    const article = document.createElement('article');

    expect(domManipulator.isProcessed(article)).toBe(false);
    domManipulator.markAsProcessed(article);
    expect(domManipulator.isProcessed(article)).toBe(true);
  });
});
