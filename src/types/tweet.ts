export interface MediaData {
  type: 'image';
  url: string;
}

export interface QuotedTweet {
  textContent: string;
  author?: string;
  media?: MediaData[];
}

export interface TweetData {
  id: string;
  element: HTMLElement;
  textContent: string;
  author?: string;
  media?: MediaData[];
  quotedTweet?: QuotedTweet;
  isRepost?: boolean;
  repostedBy?: string;
}
