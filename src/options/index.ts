import { storage } from '../shared/storage';
import { geminiNano } from '../shared/geminiNano';
import { DEFAULT_FILTER_CONFIG } from '../types/storage';
import type { OutputLanguage } from '../types/storage';

class OptionsPage {
  private elements = {
    enabled: document.getElementById('enabled') as HTMLInputElement,
    prompt: document.getElementById('prompt') as HTMLTextAreaElement,
    showStats: document.getElementById('show-stats') as HTMLInputElement,
    outputLanguage: document.getElementById('output-language') as HTMLSelectElement,
    saveBtn: document.getElementById('save-btn') as HTMLButtonElement,
    resetBtn: document.getElementById('reset-btn') as HTMLButtonElement,
    initGeminiBtn: document.getElementById('init-gemini-btn') as HTMLButtonElement,
    saveStatus: document.getElementById('save-status') as HTMLDivElement,
    textAvailability: document.getElementById('text-availability') as HTMLDivElement,
    multimodalAvailability: document.getElementById('multimodal-availability') as HTMLDivElement,
    createSessionStatus: document.getElementById('create-session-status') as HTMLDivElement,
  };
  private statusPollingInterval: number | null = null;

  async initialize(): Promise<void> {
    await this.loadConfig();
    await this.checkApiStatus();
    this.setupEventListeners();
    this.startStatusPolling();

    // Clean up on page unload
    window.addEventListener('beforeunload', () => {
      this.stopStatusPolling();
    });
  }

  private startStatusPolling(): void {
    // Poll every 5 seconds
    this.statusPollingInterval = window.setInterval(() => {
      this.checkApiStatus();
    }, 5000);
  }

  private stopStatusPolling(): void {
    if (this.statusPollingInterval !== null) {
      window.clearInterval(this.statusPollingInterval);
      this.statusPollingInterval = null;
    }
  }

  private async loadConfig(): Promise<void> {
    const config = await storage.getFilterConfig();
    this.elements.enabled.checked = config.enabled;
    this.elements.prompt.value = config.prompt;
    this.elements.showStats.checked = config.showStatistics;
    this.elements.outputLanguage.value = config.outputLanguage;
  }

  private async checkApiStatus(): Promise<void> {
    const config = await storage.getFilterConfig();

    // Check both text-only and multimodal availability
    const textAvailability = await geminiNano.checkAvailability(config.outputLanguage);
    const multimodalAvailability = await geminiNano.checkMultimodalAvailability(config.outputLanguage);

    // Display both availability statuses
    this.elements.textAvailability.textContent = `LanguageModel.availability(text): ${textAvailability}`;
    this.elements.multimodalAvailability.textContent = `LanguageModel.availability(multimodal): ${multimodalAvailability}`;

    // Determine button state based on availability
    const initBtn = this.elements.initGeminiBtn;

    // available: Model is ready (display status)
    if (textAvailability === 'available' || multimodalAvailability === 'available') {
      initBtn.disabled = true;
      initBtn.textContent = 'Model Ready';
      // Check mode status when model is available
      await this.checkModeStatus(config);
    }
    // downloadable/after-download: Download required (button is clickable)
    else if (textAvailability === 'downloadable' || textAvailability === 'after-download' ||
             multimodalAvailability === 'downloadable' || multimodalAvailability === 'after-download') {
      initBtn.disabled = false;
      initBtn.textContent = 'Download Model';
    }
    // downloading: Download in progress (display status)
    else if (textAvailability === 'downloading' || multimodalAvailability === 'downloading') {
      initBtn.disabled = true;
      initBtn.textContent = 'Downloading...';
    }
    // unavailable: Not available (display status)
    else if (textAvailability === 'unavailable' && multimodalAvailability === 'unavailable') {
      initBtn.disabled = true;
      initBtn.textContent = 'Not Available';
    }
    // Other (unknown state)
    else {
      initBtn.disabled = true;
      initBtn.textContent = 'Unknown Status';
    }
  }

  private setupEventListeners(): void {
    this.elements.saveBtn.addEventListener('click', () => this.save());
    this.elements.resetBtn.addEventListener('click', () => this.reset());
    this.elements.initGeminiBtn.addEventListener('click', () => this.initializeGemini());

    // Add click-to-copy for flag copy buttons
    document.querySelectorAll('.copy-btn').forEach((button) => {
      button.addEventListener('click', async () => {
        const url = button.getAttribute('data-url');
        if (url) {
          try {
            await navigator.clipboard.writeText(url);
            button.classList.add('copied');
            setTimeout(() => {
              button.classList.remove('copied');
            }, 1000);
          } catch (error) {
            console.error('[Tweet Filter] Failed to copy to clipboard:', error);
          }
        }
      });
    });
  }

  private async save(): Promise<void> {
    try {
      await storage.setFilterConfig({
        enabled: this.elements.enabled.checked,
        prompt: this.elements.prompt.value,
        showStatistics: this.elements.showStats.checked,
        outputLanguage: this.elements.outputLanguage.value as OutputLanguage,
      });

      this.showStatus('Settings saved successfully!', 'success');
    } catch (error) {
      this.showStatus('Failed to save settings', 'error');
      console.error('[Tweet Filter] Failed to save settings:', error);
    }
  }

  private async initializeGemini(): Promise<void> {
    const config = await storage.getFilterConfig();

    if (!config.prompt) {
      this.showStatus('Please enter filter criteria before creating session', 'error');
      return;
    }

    try {
      this.elements.initGeminiBtn.disabled = true;
      this.elements.initGeminiBtn.textContent = 'Creating...';
      this.showStatus('Creating session...', 'success', true);

      const success = await geminiNano.initialize(
        config.prompt,
        true,
        (progress) => {
          this.showStatus(`Downloading model: ${progress.toFixed(1)}%`, 'success', true);
          this.elements.initGeminiBtn.textContent = `Downloading ${progress.toFixed(0)}%`;
        },
        config.outputLanguage
      );

      if (success) {
        const createResult = geminiNano.getCreateSessionResult();
        await geminiNano.destroy();
        this.showStatus('Session created successfully!', 'success');
        await this.checkApiStatus();
        this.showCreateSessionStatus(createResult);
      } else {
        this.showStatus('Failed to create session', 'error');
        this.showCreateSessionStatus(null);
        await this.checkApiStatus();
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      this.showStatus(errorMessage, 'error');
      this.showCreateSessionStatus(null);
      console.error('[Tweet Filter] Failed to create session:', error);
      await this.checkApiStatus();
    }
  }

  private async reset(): Promise<void> {
    this.elements.enabled.checked = DEFAULT_FILTER_CONFIG.enabled;
    this.elements.prompt.value = DEFAULT_FILTER_CONFIG.prompt;
    this.elements.showStats.checked = DEFAULT_FILTER_CONFIG.showStatistics;
    this.elements.outputLanguage.value = DEFAULT_FILTER_CONFIG.outputLanguage;

    try {
      await storage.setFilterConfig({
        enabled: this.elements.enabled.checked,
        prompt: this.elements.prompt.value,
        showStatistics: this.elements.showStats.checked,
        outputLanguage: this.elements.outputLanguage.value as OutputLanguage,
      });

      this.showStatus('Settings reset to default!', 'success');
    } catch (error) {
      this.showStatus('Failed to reset settings', 'error');
      console.error('[Tweet Filter] Failed to reset settings:', error);
    }
  }

  private showStatus(message: string, type: 'success' | 'error', persistent = false): void {
    this.elements.saveStatus.textContent = message;
    this.elements.saveStatus.className = `save-status ${type}`;

    if (!persistent) {
      setTimeout(() => {
        this.elements.saveStatus.textContent = '';
        this.elements.saveStatus.className = 'save-status';
      }, 3000);
    }
  }

  private showCreateSessionStatus(result: 'multimodal' | 'text-only' | null): void {
    this.elements.createSessionStatus.textContent = `LanguageModel.create: ${result}`;
  }

  private async checkModeStatus(config: any): Promise<void> {
    if (!config.prompt) {
      this.showCreateSessionStatus(null);
      return;
    }

    try {
      const success = await geminiNano.initialize(config.prompt, false, undefined, config.outputLanguage);
      if (success) {
        const createResult = geminiNano.getCreateSessionResult();
        await geminiNano.destroy();
        this.showCreateSessionStatus(createResult);
      } else {
        this.showCreateSessionStatus(null);
      }
    } catch (error) {
      console.error('[Tweet Filter] Mode check failed with error:', error);
      this.showCreateSessionStatus(null);
    }
  }
}

const optionsPage = new OptionsPage();
optionsPage.initialize();
