// Runs without sharing deliberately: match detection must read User_Movie_Interaction__c
// records owned by other users (participants in a shared session). User_Movie_Interaction__c
// is Private OWD, so with sharing would return zero rows for the non-owning participant.
// All queries are tightly scoped to a specific sessionId + movieId pair — no arbitrary
// cross-user data is exposed. Phase 3 will implement the full match logic here.
public without sharing class MatchDetectionService {

}
