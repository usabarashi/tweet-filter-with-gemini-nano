import { CSS_CLASSES, DATA_ATTRIBUTES } from '../shared/constants';

const { PLACEHOLDER } = CSS_CLASSES;
const { COLLAPSED } = DATA_ATTRIBUTES;

export const domManipulator = {
  collapseTweet(element: HTMLElement): void {
    if (!element.isConnected) return;
    if (element.dataset[COLLAPSED]) return;

    // Create placeholder as a child of the article element.
    // This prevents X's virtual scroller from removing the article while keeping
    // the orphaned placeholder in the DOM.
    // CSS `pointer-events: none` on [data-tweet-filter-collapsed] prevents X's
    // click-to-navigate handler from firing; the placeholder re-enables
    // pointer-events for itself so the Show button remains clickable.
    const placeholder = document.createElement('div');
    placeholder.className = PLACEHOLDER;
    placeholder.innerHTML = `
      <div class="tweet-filter-placeholder-content">
        <span class="tweet-filter-icon">🔒</span>
        <span class="tweet-filter-text">Tweet hidden by filter</span>
        <button class="tweet-filter-expand-btn">Show</button>
      </div>
    `;

    // Add expand handler on the button.
    // stopPropagation prevents the click from reaching X's React root-level
    // delegation handler which would navigate to the tweet detail page.
    const expandBtn = placeholder.querySelector('.tweet-filter-expand-btn');
    expandBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      e.preventDefault();
      this.expandTweet(element);
    });

    // Insert placeholder as the first child of the article, then hide
    // original children via CSS ([data-tweet-filter-collapsed] > *:not(.tweet-filter-placeholder))
    // Using a data attribute instead of a CSS class because X's React re-renders
    // overwrite className on hover, removing any custom classes we add.
    // Data attributes survive React reconciliation since React only manages
    // attributes it knows about.
    element.prepend(placeholder);
    element.dataset[COLLAPSED] = 'true';
  },

  expandTweet(element: HTMLElement): void {
    const placeholder = element.querySelector(`.${PLACEHOLDER}`);
    placeholder?.remove();

    delete element.dataset[COLLAPSED];
  },

  markAsProcessed(element: HTMLElement): void {
    element.dataset.tweetFilterProcessed = 'true';
  },

  isProcessed(element: HTMLElement): boolean {
    return element.dataset.tweetFilterProcessed === 'true';
  },
};
