import { logger } from '../shared/logger';

export class ConnectionRegistry {
  private connections = new Map<number, chrome.runtime.Port>();

  register(port: chrome.runtime.Port): void {
    const tabId = port.sender?.tab?.id;
    if (tabId === undefined) {
      logger.warn('[ConnectionRegistry] Cannot register port without tab ID');
      return;
    }

    this.connections.set(tabId, port);
    logger.log(`[ConnectionRegistry] Registered connection for tab ${tabId}`);
  }

  unregister(port: chrome.runtime.Port): void {
    const tabId = port.sender?.tab?.id;
    if (tabId === undefined) {
      return;
    }

    this.connections.delete(tabId);
    logger.log(`[ConnectionRegistry] Unregistered connection for tab ${tabId}`);
  }

  getConnection(tabId: number): chrome.runtime.Port | undefined {
    return this.connections.get(tabId);
  }

  getAllConnections(): chrome.runtime.Port[] {
    return Array.from(this.connections.values());
  }

  getConnectionCount(): number {
    return this.connections.size;
  }

  broadcast(message: any): void {
    for (const port of this.connections.values()) {
      try {
        port.postMessage(message);
      } catch (error) {
        logger.error('[ConnectionRegistry] Failed to broadcast to port:', error);
      }
    }
  }

  clear(): void {
    this.connections.clear();
  }
}

export const connectionRegistry = new ConnectionRegistry();
