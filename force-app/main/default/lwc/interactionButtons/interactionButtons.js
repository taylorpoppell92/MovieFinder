import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import recordInteraction from '@salesforce/apex/UserInteractionService.recordInteraction';

const INTERACTION_SOURCE = 'Lightning';

const INTERACTION_TYPES = {
    THUMBS_UP: 'Thumbs_Up',
    THUMBS_DOWN: 'Thumbs_Down',
    WATCHLISTED: 'Watchlisted'
};

export default class InteractionButtons extends LightningElement {
    @api movieId;
    @api existingInteraction;
    @track isLoading = false;

    // --- Variant getters ---

    get thumbsUpVariant() {
        return this.existingInteraction === INTERACTION_TYPES.THUMBS_UP
            ? 'brand'
            : 'border-inverse';
    }

    get thumbsDownVariant() {
        return this.existingInteraction === INTERACTION_TYPES.THUMBS_DOWN
            ? 'destructive'
            : 'border-inverse';
    }

    get watchlistVariant() {
        return this.existingInteraction === INTERACTION_TYPES.WATCHLISTED
            ? 'brand'
            : 'border-inverse';
    }

    // --- Handlers ---

    handleThumbsUp() {
        this.saveInteraction(INTERACTION_TYPES.THUMBS_UP);
    }

    handleThumbsDown() {
        this.saveInteraction(INTERACTION_TYPES.THUMBS_DOWN);
    }

    handleWatchlist() {
        this.saveInteraction(INTERACTION_TYPES.WATCHLISTED);
    }

    async saveInteraction(interactionType) {
        if (this.isLoading) return;

        // Optimistically update local state so the UI feels instant
        const previousInteraction = this.existingInteraction;
        this.existingInteraction = interactionType;
        this.isLoading = true;

        try {
            await recordInteraction({
                movieId: this.movieId,
                interactionType,
                source: INTERACTION_SOURCE
            });

            this.dispatchEvent(
                new CustomEvent('interactionrecorded', {
                    detail: {
                        movieId: this.movieId,
                        interactionType
                    },
                    bubbles: true,
                    composed: true
                })
            );
        } catch (error) {
            // Revert on failure
            this.existingInteraction = previousInteraction;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Could not save',
                    message: 'Failed to record your interaction. Please try again.',
                    variant: 'error'
                })
            );
            console.error('InteractionButtons: recordInteraction failed', error);
        } finally {
            this.isLoading = false;
        }
    }
}