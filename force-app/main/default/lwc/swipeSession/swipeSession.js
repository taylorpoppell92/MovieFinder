import { LightningElement, track } from 'lwc';
import startSwipeSession from '@salesforce/apex/UserInteractionService.startSwipeSession';
import getNextSwipeMovie from '@salesforce/apex/UserInteractionService.getNextSwipeMovie';
import recordSwipe       from '@salesforce/apex/UserInteractionService.recordSwipe';
import endSwipeSession   from '@salesforce/apex/UserInteractionService.endSwipeSession';

export default class SwipeSession extends LightningElement {
    @track sessionId       = null;
    @track currentMovie    = null;
    @track isLoading       = true;
    @track isDeckExhausted = false;
    @track summary         = null;

    // Guard: prevents async callbacks from updating state after disconnection
    _connected = false;

    // -------------------------------------------------------------------------
    // Lifecycle
    // -------------------------------------------------------------------------

    connectedCallback() {
        this._connected = true;
        this._startSession();
    }

    disconnectedCallback() {
        this._connected = false;
    }

    // -------------------------------------------------------------------------
    // Computed template state
    // -------------------------------------------------------------------------

    get showCard() {
        return !this.isLoading && !!this.currentMovie && !this.isDeckExhausted;
    }

    get showEndOfDeck() {
        return !this.isLoading && this.isDeckExhausted;
    }

    // Keyed single-item list: changing the movie Id destroys and recreates
    // the swipeCard instance with fresh state on every new movie.
    get currentMovieList() {
        return this.currentMovie ? [this.currentMovie] : [];
    }

    // -------------------------------------------------------------------------
    // Session orchestration
    // -------------------------------------------------------------------------

    async _startSession() {
        this.isLoading       = true;
        this.isDeckExhausted = false;
        this.summary         = null;
        this.currentMovie    = null;

        try {
            this.sessionId = await startSwipeSession();
            if (!this._connected) return;

            const first = await getNextSwipeMovie({ sessionId: this.sessionId });
            if (!this._connected) return;

            if (first) {
                this.currentMovie = first;
            } else {
                await this._closeSession();
            }
        } catch (err) {
            console.error('SwipeSession._startSession error', err);
        } finally {
            if (this._connected) this.isLoading = false;
        }
    }

    async handleSwiped(evt) {
        const { direction, movieId } = evt.detail;

        // Fire-and-forget the write so next-card fetch runs in parallel
        recordSwipe({ movieId, direction, sessionId: this.sessionId })
            .catch(err => console.error('recordSwipe error', err));

        try {
            const next = await getNextSwipeMovie({ sessionId: this.sessionId });
            if (!this._connected) return;

            if (next) {
                this.currentMovie = next;
            } else {
                this.currentMovie = null;
                await this._closeSession();
            }
        } catch (err) {
            console.error('getNextSwipeMovie error', err);
        }
    }

    async _closeSession() {
        try {
            this.summary = await endSwipeSession({ sessionId: this.sessionId });
        } catch (err) {
            console.error('endSwipeSession error', err);
        }

        if (!this._connected) return;

        this.isDeckExhausted = true;

        // Notify parent (movieFinderApp or a future shared-session coordinator)
        this.dispatchEvent(new CustomEvent('sessionended', {
            detail:   { ...(this.summary ?? {}) },
            bubbles:  false,
            composed: false
        }));
    }

    handleSwipeAgain() {
        this._startSession();
    }
}
