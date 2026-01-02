import { CSS_CLASSES } from '../shared/constants';

const { COLLAPSED, PLACEHOLDER } = CSS_CLASSES;

export const domManipulator = {
  collapseTweet(element: HTMLElement): void {
    if (!element.isConnected) return;
    if (element.classList.contains(COLLAPSED)) return;

    // Store original display
    const originalDisplay = element.style.display;
    element.dataset.originalDisplay = originalDisplay;
    element.classList.add(COLLAPSED);
    element.style.display = 'none';

    // Create placeholder
    const placeholder = document.createElement('div');
    placeholder.className = PLACEHOLDER;
    placeholder.innerHTML = `
      <div class="tweet-filter-placeholder-content">
        <span class="tweet-filter-icon">🔒</span>
        <span class="tweet-filter-text">Tweet hidden by filter</span>
        <button class="tweet-filter-expand-btn">Show</button>
      </div>
    `;

    // Add click handler
    const expandBtn = placeholder.querySelector('.tweet-filter-expand-btn');
    expandBtn?.addEventListener('click', () => {
      this.expandTweet(element);
    });

    element.parentNode?.insertBefore(placeholder, element);
  },

  expandTweet(element: HTMLElement): void {
    const placeholder = element.previousElementSibling;
    if (placeholder?.classList.contains(PLACEHOLDER)) {
      placeholder.remove();
    }

    element.classList.remove(COLLAPSED);
    element.style.display = element.dataset.originalDisplay ?? '';
    delete element.dataset.originalDisplay;
  },

  markAsProcessed(element: HTMLElement): void {
    element.dataset.tweetFilterProcessed = 'true';
  },

  isProcessed(element: HTMLElement): boolean {
    return element.dataset.tweetFilterProcessed === 'true';
  },
};
