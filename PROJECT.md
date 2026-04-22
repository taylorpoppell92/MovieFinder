# MovieFinder — Project Overview

## Vision

MovieFinder is a Salesforce application that solves a simple problem: **what free movies can I watch right now across all my streaming services?**

The app aggregates movie availability across every streaming service the user subscribes to, surfaces them in a browsable UI, and lets the user rate movies (thumbs up/down) to help decide what to watch. Future phases will introduce a Tinder-style swipe interface and AI-powered recommendations.

---

## Roadmap

### Phase 1 — Internal Salesforce App ✅ (Current)
- Browse all movies available on user's subscriptions
- Thumbs up / thumbs down rating
- Filter by streaming service
- Paginated movie grid with poster art
- User manages their own subscription list

### Phase 2 — Swipe UX + Mobile
- Tinder-style swipe left (skip) / right (interested) on full-screen movie cards
- Swipe session tracking (grouped interactions)
- Salesforce Mobile app support
- Touch gesture support in LWC

### Phase 3 — AI Recommendations (Agentforce)
- Agentforce agent ranks movies based on user's interaction history
- "If you liked X, you'd like Y" pre-computed recommendation graph
- Natural language movie search ("show me 90s sci-fi on Netflix")
- Preference inference after 20+ rated movies

---

## Technical Architecture

### Core Principle: Hybrid Thin-Cache Model
Salesforce is the **system of record for user data** (subscriptions, ratings, interactions). TMDB is the **system of record for movie catalog data**. Movie records in Salesforce are a thin cache keyed by TMDB ID — not a full replica.

### API Strategy: TMDB (The Movie Database)
- **Free tier**, no monthly cap, commercial use allowed with attribution
- Single integration point replacing what would otherwise be N streaming service APIs
- Watch Providers endpoint returns flatrate/subscription availability by region
- `TMDB_Id__c` as external ID enables idempotent upserts on every sync
- Poster/backdrop images served directly from TMDB's CDN — no Salesforce storage cost

**Why not JustWatch?** Unofficial, undocumented API with no stable contract. Any UI refactor on their end silently breaks Apex callouts with zero warning.

**Why not individual streaming service APIs?** Netflix, Hulu, Disney+ do not have public OAuth APIs that allow third-party apps to query subscription catalogs. The user self-declares their subscriptions in `User_Subscription__c`; TMDB's Watch Providers data surfaces what's available on those services.

### Deployment Scope
Always deploy using the scoped manifest — never the full source directory (which includes standard org metadata with volatile ListViews):

```bash
sf project deploy start --manifest package-moviepicker.xml --target-org devorg
```

---

## Data Model

### `Streaming_Service__c`
Static reference catalog of streaming services. ~10–15 records, maintained manually.

| Field | Type | Notes |
|---|---|---|
| Name | Text | "Netflix", "Hulu", "Disney+" |
| Service_Key__c | Text(50), Ext ID | "netflix", "hulu" |
| TMDB_Provider_Id__c | Number | TMDB's integer ID (Netflix=8, Prime=9, Disney+=337) |
| Logo_URL__c | URL | |
| Is_Active__c | Checkbox | |

### `Movie__c`
Thin TMDB cache. Holds only what's needed to render a movie card without a round-trip.

| Field | Type | Notes |
|---|---|---|
| Name | Text | Movie title |
| TMDB_Id__c | Text(20), Ext ID | Primary join key to TMDB |
| Poster_URL__c | URL | Append to `https://image.tmdb.org/t/p/w500` |
| Backdrop_URL__c | URL | Append to `https://image.tmdb.org/t/p/w1280` |
| Release_Year__c | Number | Parsed from TMDB `release_date` |
| Genre_Tags__c | Text(255) | Comma-separated TMDB genre IDs |
| Runtime_Minutes__c | Number | Only populated via detail endpoint |
| Content_Rating__c | Picklist | G, PG, PG-13, R, NC-17, NR |
| Aggregate_Rating__c | Number(3,1) | TMDB vote_average (0–10) |
| Overview__c | LongTextArea | Short synopsis |
| TMDB_Popularity__c | Number | Used for default sort order |
| Last_Synced__c | DateTime | Cache invalidation |

### `User_Subscription__c` (OWD: Private)
The user's declared streaming service memberships. Drives the "free to you" filter.

| Field | Type | Notes |
|---|---|---|
| User__c | Lookup(User) | |
| Streaming_Service__c | Lookup(Streaming_Service__c) | |
| Is_Active__c | Checkbox | |
| Verified_At__c | DateTime | Future: OAuth verification timestamp |

### `Movie_Availability__c` (Master-Detail → Movie__c)
Junction: this movie is free on this service right now. Most volatile data — refreshed nightly.

| Field | Type | Notes |
|---|---|---|
| Movie__c | MasterDetail(Movie__c) | |
| Streaming_Service__c | Lookup(Streaming_Service__c) | |
| Availability_Type__c | Picklist | Subscription, Rent, Buy, Free |
| Available_As_Of__c | DateTime | |
| Expires_At__c | DateTime | When known |

### `User_Movie_Interaction__c` (OWD: Private)
All user ratings and future swipe decisions. One object handles both current and Phase 2 UX.

| Field | Type | Notes |
|---|---|---|
| User__c | Lookup(User) | |
| Movie__c | Lookup(Movie__c) | |
| Interaction_Type__c | Picklist | Thumbs_Up, Thumbs_Down, Swipe_Right, Swipe_Left, Watchlisted, Watched |
| Interaction_Source__c | Picklist | Lightning, Mobile, Swipe_Session |
| Interaction_DateTime__c | DateTime | |
| Swipe_Session_Id__c | Text(36) | UUID grouping a single swipe session — null for non-swipe interactions |

**Business rule:** A user can only have one active Thumbs_Up **or** Thumbs_Down per movie — toggling one removes the other. Implemented in `UserInteractionService`.

---

## Apex Layer

| Class | Purpose |
|---|---|
| `TmdbApiService` | All TMDB v3 callouts. Cached config via `TMDB_Config__mdt`. Named Credential `TMDB_API`. |
| `MovieFinderController` | `@AuraEnabled` methods for LWC: browse movies, get/upsert subscriptions. |
| `UserInteractionService` | Thumbs up/down (with mutual exclusivity), swipe session management, watchlist. |
| `MovieAvailabilitySync` | Queueable that pages through TMDB `/discover/movie` for one provider, upserts `Movie__c` and `Movie_Availability__c`. Chains to next page automatically. |
| `MovieAvailabilitySyncScheduler` | Scheduled Apex entry point. Fires nightly at 2am, enqueues one `MovieAvailabilitySync` per active streaming service. |

**Nightly sync schedule (to activate):**
```apex
System.schedule('MovieFinder Nightly Sync', '0 0 2 * * ?', new MovieAvailabilitySyncScheduler());
```

### TMDB API Key Setup
The API key lives only in the org — never in source control.

1. Go to Setup → Custom Metadata Types → TMDB Config → Manage Records
2. Edit the **Default** record
3. Paste your TMDB v3 API key into the `API Key` field

Or via SFDX (replace the placeholder before deploying):
```
force-app/main/default/customMetadata/TMDB_Config.Default.md-meta.xml
```

---

## LWC Component Hierarchy

```
movieFinderApp        — Tabbed shell: "Browse" + "My Services"
  ├── subscriptionManager   — Toggle cards for each streaming service
  └── movieBrowser          — Paginated movie feed, manages filter state
       ├── movieFilterBar    — Service/genre filter dropdown
       └── movieGrid         — CSS grid of movie cards
            └── movieCard    — Poster, overlay, rating badge
                 └── interactionButtons  — Thumbs up/down/watchlist with optimistic UI
```

**Key design decisions:**
- `movieBrowser` uses `@api get/set` on `serviceFilter` to detect parent-driven property changes and reset + reload the movie list
- `interactionButtons` updates local state optimistically before the Apex round-trip completes, reverts on failure
- `interactionrecorded` custom event bubbles with `composed: true` up through `movieCard → movieGrid → movieBrowser` where it updates the movies array to re-render
- TMDB poster images use the CDN directly (`https://image.tmdb.org/t/p/w500{posterPath}`) — no Salesforce Files storage

---

## Security Model

| Object | OWD | Notes |
|---|---|---|
| Movie__c | Read/Write (Public Read) | Catalog data — all users see all movies |
| Streaming_Service__c | Read/Write (Public Read) | Reference data |
| User_Subscription__c | Private | Users see only their own subscriptions |
| Movie_Availability__c | Controlled by Parent | Inherits from Movie__c |
| User_Movie_Interaction__c | Private | Users see only their own interactions |

**Permission Set:** `MovieFinder_User` grants all necessary object/field access. Assign to any user who should access the app.

All Apex controller classes use `with sharing` — sharing rules are enforced on all SOQL queries.

---

## Deployment Checklist

- [ ] Add TMDB API key to `TMDB_Config__mdt` Default record in the org
- [ ] Deploy using `sf project deploy start --manifest package-moviepicker.xml --target-org devorg`
- [ ] Seed `Streaming_Service__c` records with TMDB provider IDs (Netflix=8, Prime Video=9, Disney+=337, Hulu=15, Max=1899, Apple TV+=350)
- [ ] Run nightly sync manually to seed initial movie catalog: `System.enqueueJob(new MovieAvailabilitySync(netflixServiceId, 1))`
- [ ] Schedule the nightly job: `System.schedule('MovieFinder Nightly Sync', '0 0 2 * * ?', new MovieAvailabilitySyncScheduler())`
- [ ] Add `movieFinderApp` to a Lightning App Page
- [ ] Assign `MovieFinder_User` permission set to users

---

## Repository

GitHub: [https://github.com/taylorpoppell92/MovieFinder](https://github.com/taylorpoppell92/MovieFinder)  
Connected Org: `devorg` (taylor.poppell.fb42c566d1da@agentforce.com)  
API Version: 66.0
