import { LightningElement, api, track } from 'lwc';

const TMDB_IMAGE_BASE  = 'https://image.tmdb.org/t/p/w780';
const SWIPE_THRESHOLD  = 100;  // px before a drag is committed as a swipe
const MAX_ROTATION_DEG = 15;   // degrees of tilt at exactly the threshold distance

export default class SwipeCard extends LightningElement {
    @api movie;
    @api sessionId;
    @track showFallback = false;

    // Private drag state — not reactive, updated imperatively for perf
    _isDragging = false;
    _startX     = 0;
    _currentDx  = 0;

    // -------------------------------------------------------------------------
    // Computed props
    // -------------------------------------------------------------------------

    get movieTitle()      { return this.movie?.Name              ?? ''; }
    get movieYear()       { return this.movie?.Release_Year__c   ?? null; }
    get contentRating()   { return this.movie?.Content_Rating__c ?? null; }
    get runtime()         { return this.movie?.Runtime_Minutes__c ?? null; }
    get overview()        { return this.movie?.Overview__c       ?? null; }
    get aggregateRating() { return this.movie?.Aggregate_Rating__c ?? null; }

    get imageUrl() {
        const poster = this.movie?.Poster_URL__c;
        if (!poster) return null;
        return poster.startsWith('http') ? poster : TMDB_IMAGE_BASE + poster;
    }

    // -------------------------------------------------------------------------
    // Image fallback
    // -------------------------------------------------------------------------

    handleImageError() {
        this.showFallback = true;
    }

    // -------------------------------------------------------------------------
    // Drag start
    // -------------------------------------------------------------------------

    handleDragStart(e) {
        e.preventDefault();
        this._isDragging = true;
        this._startX     = e.touches ? e.touches[0].clientX : e.clientX;
        this._currentDx  = 0;
    }

    // -------------------------------------------------------------------------
    // Drag move — update transform + overlay imperatively (no reactive re-render)
    // -------------------------------------------------------------------------

    handleDragMove(e) {
        if (!this._isDragging) return;
        const clientX    = e.touches ? e.touches[0].clientX : e.clientX;
        this._currentDx  = clientX - this._startX;
        this._applyDragStyle(this._currentDx);
    }

    // -------------------------------------------------------------------------
    // Drag end — commit or cancel
    // -------------------------------------------------------------------------

    handleDragEnd() {
        if (!this._isDragging) return;
        this._isDragging = false;

        if (Math.abs(this._currentDx) >= SWIPE_THRESHOLD) {
            this._flyOut(this._currentDx > 0 ? 'right' : 'left');
        } else {
            this._snapBack();
        }
    }

    handleDragCancel() {
        if (!this._isDragging) return;
        this._isDragging = false;
        this._snapBack();
    }

    // -------------------------------------------------------------------------
    // Imperative style helpers
    // -------------------------------------------------------------------------

    _applyDragStyle(dx) {
        const card    = this.template.querySelector('.swipe-card');
        const overlay = this.template.querySelector('.drag-overlay');
        const like    = this.template.querySelector('.like-indicator');
        const skip    = this.template.querySelector('.skip-indicator');
        if (!card) return;

        const rotation = (dx / SWIPE_THRESHOLD) * MAX_ROTATION_DEG;
        card.style.transform = `translateX(${dx}px) rotate(${rotation}deg)`;

        const ratio   = Math.min(Math.abs(dx) / SWIPE_THRESHOLD, 1);
        const alpha   = ratio * 0.4;

        if (dx > 0) {
            overlay.style.backgroundColor = `rgba(34, 197, 94, ${alpha})`;
            like.style.opacity = String(ratio);
            skip.style.opacity = '0';
        } else {
            overlay.style.backgroundColor = `rgba(239, 68, 68, ${alpha})`;
            skip.style.opacity = String(ratio);
            like.style.opacity = '0';
        }
    }

    _snapBack() {
        const card    = this.template.querySelector('.swipe-card');
        const overlay = this.template.querySelector('.drag-overlay');
        const like    = this.template.querySelector('.like-indicator');
        const skip    = this.template.querySelector('.skip-indicator');
        if (!card) return;

        card.style.transition = 'transform 0.3s ease';
        card.style.transform  = '';
        overlay.style.backgroundColor = 'transparent';
        like.style.opacity = '0';
        skip.style.opacity = '0';

        // Clear the transition property after the snap-back completes so it
        // does not interfere with the next drag gesture.
        setTimeout(() => { card.style.transition = ''; }, 300); // eslint-disable-line @lwc/lwc/no-async-operation
    }

    // Fly the card off screen and fire the swiped event simultaneously so the
    // parent can start the next Apex callout while the animation plays.
    _flyOut(direction) {
        const card = this.template.querySelector('.swipe-card');
        if (!card) return;

        const tx     = direction === 'right' ? '150vw' : '-150vw';
        const rotate = direction === 'right' ? '25deg'  : '-25deg';

        card.style.transition = 'transform 0.25s ease, opacity 0.2s ease';
        card.style.transform  = `translateX(${tx}) rotate(${rotate})`;
        card.style.opacity    = '0';

        this.dispatchEvent(new CustomEvent('swiped', {
            detail:   { direction, movieId: this.movie?.Id, sessionId: this.sessionId },
            bubbles:  true,
            composed: true
        }));
    }
}
