----------------------------- MODULE TweetFilter -----------------------------
(*
 * TLA+ formal specification for Tweet Filter with Gemini Nano
 *
 * Models the concurrent message-passing architecture of a Chrome Extension
 * that filters tweets using on-device AI (Gemini Nano).
 *
 * Architecture:
 *   Content Script  <-->  Background (Service Worker)  <-->  Offscreen Document
 *
 * Key concurrency aspects modeled:
 *   1. Asynchronous message passing between three processes
 *   2. LRU cache with mutex in Background
 *   3. Serial evaluation queue with generation-based cancellation in Offscreen
 *   4. Session lifecycle (Uninitialized -> Initialized) with init lock
 *   5. Config changes triggering cache clear and session reinit
 *
 * Memory analysis focus:
 *   - TotalMemoryPressure tracks aggregate resource retention across components
 *   - DOM element references held in content queue (TweetData.element)
 *   - Aff fiber closures blocked on AVar mutexes in offscreen
 *   - Orphaned messages in channels without consumers
 *   - Cloned Gemini Nano sessions during evaluation
 *)
EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS
    TweetIds,           \* Set of possible tweet IDs
    MaxCacheSize,       \* Maximum number of entries in the cache
    MaxQueueLen,        \* Maximum evaluation queue length
    MaxInFlight,        \* Maximum number of in-flight requests
    MaxMemoryBudget     \* Maximum acceptable total memory units

ASSUME MaxCacheSize \in Nat \ {0}
ASSUME MaxQueueLen \in Nat \ {0}
ASSUME MaxInFlight \in Nat \ {0}
ASSUME MaxMemoryBudget \in Nat \ {0}

-----------------------------------------------------------------------------
(* Message types *)

MessageTypes == {
    "InitRequest", "InitResponse",
    "EvaluateRequest", "EvaluateResponse",
    "ReinitRequest",
    "CacheCheckRequest", "CacheCheckResponse",
    "ConfigChanged",
    "ErrorMessage"
}

SessionTypes == {"Multimodal", "TextOnly"}

FilteringModes == {"Enabled", "Disabled"}

SessionRuntimes == {"Uninitialized", "Initialized"}

EvalResults == {TRUE, FALSE}  \* shouldShow: TRUE = show, FALSE = hide

-----------------------------------------------------------------------------
(* Variables *)

VARIABLES
    \* --- Content Script state ---
    contentQueue,       \* Sequence of TweetIds waiting to be sent
    contentGeneration,  \* Generation counter for queue cancellation
    contentProcessing,  \* Whether content script is processing queue
    filteringMode,      \* "Enabled" | "Disabled"

    \* --- Background state ---
    cache,              \* Function TweetId -> EvalResult (partial)
    cacheOrder,         \* Sequence of TweetIds for LRU ordering
    cacheLocked,        \* Boolean: whether cache mutex is held
    offscreenExists,    \* Boolean: whether offscreen document is created
    offscreenLocked,    \* Boolean: whether offscreen creation mutex is held
    bgWaitingFibers,    \* Number of Background Aff fibers blocked on offscreen response

    \* --- Offscreen state ---
    sessionRuntime,     \* "Uninitialized" | "Initialized"
    sessionType,        \* Element of SessionTypes or "None"
    sessionInitLocked,  \* Boolean: whether init lock is held
    evalQueue,          \* Sequence of TweetIds in evaluation queue
    evalQueueGen,       \* Generation counter for eval queue
    evalQueueLocked,    \* Boolean: whether eval queue mutex is held
    evalInProgress,     \* TweetId currently being evaluated, or "None"
    clonedSessions,     \* Number of cloned Gemini Nano sessions in memory

    \* --- Message channels (unordered, bounded) ---
    contentToBg,        \* Set of messages from Content to Background
    bgToOffscreen,      \* Set of messages from Background to Offscreen
    offscreenToBg,      \* Set of messages from Offscreen to Background
    bgToContent,        \* Set of messages from Background to Content

    \* --- Configuration ---
    currentConfig       \* Record: [enabled: BOOLEAN]

vars == <<
    contentQueue, contentGeneration, contentProcessing, filteringMode,
    cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
    sessionRuntime, sessionType, sessionInitLocked,
    evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
    contentToBg, bgToOffscreen, offscreenToBg, bgToContent,
    currentConfig
>>

-----------------------------------------------------------------------------
(* Type invariant *)

TypeOK ==
    /\ contentQueue \in Seq(TweetIds)
    /\ contentGeneration \in Nat
    /\ contentProcessing \in BOOLEAN
    /\ filteringMode \in FilteringModes
    /\ DOMAIN cache \subseteq TweetIds
    /\ \A t \in DOMAIN cache : cache[t] \in BOOLEAN
    /\ cacheOrder \in Seq(TweetIds)
    /\ cacheLocked \in BOOLEAN
    /\ offscreenExists \in BOOLEAN
    /\ offscreenLocked \in BOOLEAN
    /\ bgWaitingFibers \in Nat
    /\ sessionRuntime \in SessionRuntimes
    /\ sessionType \in SessionTypes \cup {"None"}
    /\ sessionInitLocked \in BOOLEAN
    /\ evalQueue \in Seq(TweetIds)
    /\ evalQueueGen \in Nat
    /\ evalQueueLocked \in BOOLEAN
    /\ evalInProgress \in TweetIds \cup {"None"}
    /\ clonedSessions \in Nat
    /\ IsFiniteSet(contentToBg)
    /\ IsFiniteSet(bgToOffscreen)
    /\ IsFiniteSet(offscreenToBg)
    /\ IsFiniteSet(bgToContent)
    /\ currentConfig \in [enabled: BOOLEAN]

-----------------------------------------------------------------------------
(* Helper operators *)

CacheSize == Cardinality(DOMAIN cache)

\* Remove the first occurrence of elem from seq
RemoveFirst(seq, elem) ==
    LET idx == CHOOSE i \in 1..Len(seq) : seq[i] = elem
    IN SubSeq(seq, 1, idx - 1) \o SubSeq(seq, idx + 1, Len(seq))

\* Check if elem is in sequence
SeqContains(seq, elem) ==
    \E i \in 1..Len(seq) : seq[i] = elem

\* Move element to end of LRU order (promote)
PromoteLRU(order, elem) ==
    IF SeqContains(order, elem)
    THEN Append(RemoveFirst(order, elem), elem)
    ELSE Append(order, elem)

-----------------------------------------------------------------------------
(* Memory cost model *)
(*
 * Each component holds resources in memory. We assign abstract "memory units"
 * to each resource type to track total pressure across all components.
 *
 * Cost weights (abstract, relative):
 *   - Content queue entry (TweetData with DOM Element ref): 3 units
 *     Source: src/shared/Types/Tweet.purs TweetData holds element :: Element
 *   - Cache entry (tweetId -> Boolean in chrome.storage.session): 1 unit
 *   - Message in channel (Foreign object): 1 unit
 *   - Background waiting fiber (Aff closure + sendResponse callback): 2 units
 *   - Eval queue entry (Aff closure blocked on AVar): 2 units
 *   - Cloned Gemini Nano session (model weights in GPU/CPU memory): 5 units
 *   - In-progress evaluation (cloned session + prompt context): 5 units
 *)
MemCostContentQueueEntry == 3
MemCostCacheEntry == 1
MemCostMessage == 1
MemCostBgFiber == 2
MemCostEvalQueueEntry == 2
MemCostClonedSession == 5

\* Total memory pressure across all components
TotalMemoryPressure ==
    \* Content: queue entries hold TweetData with DOM element references
      Len(contentQueue) * MemCostContentQueueEntry
    \* Background: cache entries in chrome.storage.session
    + CacheSize * MemCostCacheEntry
    \* Background: Aff fibers blocked waiting for offscreen response
    + bgWaitingFibers * MemCostBgFiber
    \* Offscreen: evaluation queue entries (Aff closures blocked on AVar)
    + Len(evalQueue) * MemCostEvalQueueEntry
    \* Offscreen: cloned Gemini Nano sessions
    + clonedSessions * MemCostClonedSession
    \* Channel messages in transit
    + Cardinality(contentToBg) * MemCostMessage
    + Cardinality(bgToOffscreen) * MemCostMessage
    + Cardinality(offscreenToBg) * MemCostMessage
    + Cardinality(bgToContent) * MemCostMessage

-----------------------------------------------------------------------------
(* Initial state *)

Init ==
    /\ contentQueue = <<>>
    /\ contentGeneration = 0
    /\ contentProcessing = FALSE
    /\ filteringMode = "Enabled"
    /\ cache = <<>>
    /\ cacheOrder = <<>>
    /\ cacheLocked = FALSE
    /\ offscreenExists = FALSE
    /\ offscreenLocked = FALSE
    /\ bgWaitingFibers = 0
    /\ sessionRuntime = "Uninitialized"
    /\ sessionType = "None"
    /\ sessionInitLocked = FALSE
    /\ evalQueue = <<>>
    /\ evalQueueGen = 0
    /\ evalQueueLocked = FALSE
    /\ evalInProgress = "None"
    /\ clonedSessions = 0
    /\ contentToBg = {}
    /\ bgToOffscreen = {}
    /\ offscreenToBg = {}
    /\ bgToContent = {}
    /\ currentConfig = [enabled |-> TRUE]

-----------------------------------------------------------------------------
(* Content Script Actions *)

\* A new tweet is discovered in the DOM.
\* MEMORY ISSUE: No backpressure - contentQueue grows unbounded by evaluation speed.
\* Each entry holds a TweetData record containing an Element DOM reference
\* (src/shared/Types/Tweet.purs:50-58), preventing GC of off-screen DOM nodes.
DiscoverTweet(tid) ==
    /\ filteringMode = "Enabled"
    /\ tid \notin {contentQueue[i] : i \in 1..Len(contentQueue)}
    /\ Len(contentQueue) < MaxQueueLen
    /\ contentQueue' = Append(contentQueue, tid)
    /\ UNCHANGED <<contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToOffscreen, offscreenToBg, bgToContent,
                   currentConfig>>

\* Content script sends the next queued tweet to Background for evaluation.
\* Processing is serial: contentProcessing prevents concurrent sends.
SendEvaluateRequest ==
    /\ filteringMode = "Enabled"
    /\ Len(contentQueue) > 0
    /\ ~contentProcessing
    /\ Cardinality(contentToBg) < MaxInFlight
    /\ LET tid == Head(contentQueue)
       IN /\ contentToBg' = contentToBg \cup
               {[type |-> "EvaluateRequest",
                 tweetId |-> tid,
                 generation |-> contentGeneration]}
          /\ contentQueue' = Tail(contentQueue)
          /\ contentProcessing' = TRUE
    /\ UNCHANGED <<contentGeneration, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   bgToOffscreen, offscreenToBg, bgToContent,
                   currentConfig>>

\* Content script receives an evaluation response
ReceiveEvaluateResponse ==
    /\ \E msg \in bgToContent :
        /\ msg.type = "EvaluateResponse"
        /\ contentProcessing' = FALSE
        /\ bgToContent' = bgToContent \ {msg}
    /\ UNCHANGED <<contentQueue, contentGeneration, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToOffscreen, offscreenToBg,
                   currentConfig>>

\* Content script sends init request to Background
SendInitRequest ==
    /\ filteringMode = "Enabled"
    /\ Cardinality(contentToBg) < MaxInFlight
    /\ contentToBg' = contentToBg \cup
        {[type |-> "InitRequest"]}
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   bgToOffscreen, offscreenToBg, bgToContent,
                   currentConfig>>

-----------------------------------------------------------------------------
(* Background Actions *)

\* Background handles InitRequest: forward to offscreen.
\* MEMORY ISSUE: Each forwarded message creates a blocked Aff fiber in Background.
BgHandleInitRequest ==
    /\ \E msg \in contentToBg :
        /\ msg.type = "InitRequest"
        /\ contentToBg' = contentToBg \ {msg}
        /\ Cardinality(bgToOffscreen) < MaxInFlight
        /\ bgToOffscreen' = bgToOffscreen \cup
            {[type |-> "InitRequest", source |-> "content"]}
        /\ bgWaitingFibers' = bgWaitingFibers + 1
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   offscreenToBg, bgToContent,
                   currentConfig>>

\* Background handles EvaluateRequest: cache hit
BgHandleEvaluateRequest_CacheHit ==
    /\ \E msg \in contentToBg :
        /\ msg.type = "EvaluateRequest"
        /\ msg.tweetId \in DOMAIN cache
        /\ ~cacheLocked
        /\ LET result == cache[msg.tweetId]
           IN /\ bgToContent' = bgToContent \cup
                   {[type |-> "EvaluateResponse",
                     tweetId |-> msg.tweetId,
                     shouldShow |-> result,
                     cacheHit |-> TRUE]}
              /\ cacheOrder' = PromoteLRU(cacheOrder, msg.tweetId)
        /\ contentToBg' = contentToBg \ {msg}
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   bgToOffscreen, offscreenToBg,
                   currentConfig>>

\* Background handles EvaluateRequest: cache miss, forward to offscreen.
\* MEMORY ISSUE: Creates a blocked Aff fiber holding the message closure
\* and sendResponse callback (src/background/Main.purs:60-66).
BgHandleEvaluateRequest_CacheMiss ==
    /\ \E msg \in contentToBg :
        /\ msg.type = "EvaluateRequest"
        /\ msg.tweetId \notin DOMAIN cache
        /\ Cardinality(bgToOffscreen) < MaxInFlight
        /\ contentToBg' = contentToBg \ {msg}
        /\ bgToOffscreen' = bgToOffscreen \cup
            {[type |-> "EvaluateRequest",
              tweetId |-> msg.tweetId]}
        /\ bgWaitingFibers' = bgWaitingFibers + 1
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   offscreenToBg, bgToContent,
                   currentConfig>>

\* Background receives eval response from offscreen, caches result, forwards to content.
\* Releases one waiting fiber.
BgForwardEvaluateResponse ==
    /\ \E msg \in offscreenToBg :
        /\ msg.type = "EvaluateResponse"
        /\ ~cacheLocked
        /\ offscreenToBg' = offscreenToBg \ {msg}
        /\ IF CacheSize >= MaxCacheSize
           THEN /\ Len(cacheOrder) > 0
                /\ LET victim == Head(cacheOrder)
                   IN /\ cache' = [t \in (DOMAIN cache \ {victim}) \cup {msg.tweetId} |->
                                    IF t = msg.tweetId THEN msg.shouldShow
                                    ELSE cache[t]]
                      /\ cacheOrder' = Append(Tail(cacheOrder), msg.tweetId)
           ELSE /\ cache' = [t \in DOMAIN cache \cup {msg.tweetId} |->
                              IF t = msg.tweetId THEN msg.shouldShow
                              ELSE cache[t]]
                /\ cacheOrder' = Append(cacheOrder, msg.tweetId)
        /\ bgToContent' = bgToContent \cup
            {[type |-> "EvaluateResponse",
              tweetId |-> msg.tweetId,
              shouldShow |-> msg.shouldShow,
              cacheHit |-> FALSE]}
        /\ bgWaitingFibers' = bgWaitingFibers - 1
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cacheLocked, offscreenExists, offscreenLocked,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToOffscreen,
                   currentConfig>>

\* Background forwards InitResponse (content-originated) to content.
\* Releases one waiting fiber.
BgForwardInitResponse ==
    /\ \E msg \in offscreenToBg :
        /\ msg.type = "InitResponse"
        /\ msg.source = "content"
        /\ offscreenToBg' = offscreenToBg \ {msg}
        /\ bgToContent' = bgToContent \cup {[type |-> msg.type, success |-> msg.success, sessionType |-> msg.sessionType]}
        /\ bgWaitingFibers' = bgWaitingFibers - 1
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToOffscreen,
                   currentConfig>>

\* Background consumes InitResponse from config-originated reinit.
\* No fiber tracking needed: onConfigChange handles response directly.
BgConsumeReinitResponse ==
    /\ \E msg \in offscreenToBg :
        /\ msg.type = "InitResponse"
        /\ msg.source = "config"
        /\ offscreenToBg' = offscreenToBg \ {msg}
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToOffscreen, bgToContent,
                   currentConfig>>

-----------------------------------------------------------------------------
(* Offscreen Actions *)

\* Offscreen ensures document exists (lazy creation)
EnsureOffscreenDocument ==
    /\ ~offscreenExists
    /\ ~offscreenLocked
    /\ offscreenExists' = TRUE
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToOffscreen, offscreenToBg, bgToContent,
                   currentConfig>>

\* Offscreen handles InitRequest: initialize session
OffscreenHandleInitRequest ==
    /\ \E msg \in bgToOffscreen :
        /\ msg.type = "InitRequest"
        /\ ~sessionInitLocked
        /\ bgToOffscreen' = bgToOffscreen \ {msg}
        /\ \/ /\ sessionRuntime' = "Initialized"
              /\ sessionType' \in SessionTypes
              /\ offscreenToBg' = offscreenToBg \cup
                  {[type |-> "InitResponse",
                    success |-> TRUE,
                    sessionType |-> sessionType',
                    source |-> msg.source]}
           \/ /\ sessionRuntime' = "Uninitialized"
              /\ sessionType' = "None"
              /\ offscreenToBg' = offscreenToBg \cup
                  {[type |-> "InitResponse",
                    success |-> FALSE,
                    sessionType |-> "None",
                    source |-> msg.source]}
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToContent,
                   currentConfig>>

\* Offscreen handles EvaluateRequest: enqueue for serial processing.
\* MEMORY ISSUE: Each enqueued item creates an Aff fiber blocked on AVar.take
\* (src/offscreen/EvaluationQueue.purs:46-57). The fiber closure holds
\* the entire evaluation action including session references.
OffscreenEnqueueEvaluation ==
    /\ \E msg \in bgToOffscreen :
        /\ msg.type = "EvaluateRequest"
        /\ sessionRuntime = "Initialized"
        /\ Len(evalQueue) < MaxQueueLen
        /\ bgToOffscreen' = bgToOffscreen \ {msg}
        /\ evalQueue' = Append(evalQueue, msg.tweetId)
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, offscreenToBg, bgToContent,
                   currentConfig>>

\* Offscreen processes next item in evaluation queue (serial).
\* Allocates a cloned Gemini Nano session for evaluation.
\* MEMORY ISSUE: Cloned session holds model weights in GPU/CPU memory
\* (src/offscreen/EvaluationService.purs:54-57 bracket createClonedSession).
OffscreenProcessEvaluation ==
    /\ Len(evalQueue) > 0
    /\ evalInProgress = "None"
    /\ ~evalQueueLocked
    /\ LET tid == Head(evalQueue)
       IN /\ evalInProgress' = tid
          /\ evalQueue' = Tail(evalQueue)
    /\ clonedSessions' = clonedSessions + 1
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueueGen, evalQueueLocked,
                   contentToBg, bgToOffscreen, offscreenToBg, bgToContent,
                   currentConfig>>

\* Offscreen completes evaluation (nondeterministic result).
\* Releases the cloned session (bracket ensures cleanup).
OffscreenCompleteEvaluation ==
    /\ evalInProgress /= "None"
    /\ \E shouldShow \in BOOLEAN :
        /\ offscreenToBg' = offscreenToBg \cup
            {[type |-> "EvaluateResponse",
              tweetId |-> evalInProgress,
              shouldShow |-> shouldShow]}
        /\ evalInProgress' = "None"
        /\ clonedSessions' = clonedSessions - 1
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked,
                   contentToBg, bgToOffscreen, bgToContent,
                   currentConfig>>

\* Offscreen handles ReinitRequest: clear queue, reinitialize session.
\* MEMORY ISSUE: clear creates a NEW AVar lock (src/offscreen/EvaluationQueue.purs:38-40).
\* Old AVar stays alive until all fibers blocked on it complete.
\* evalInProgress evaluation continues with the OLD cloned session.
OffscreenHandleReinit ==
    /\ \E msg \in bgToOffscreen :
        /\ msg.type = "ReinitRequest"
        /\ ~sessionInitLocked
        /\ bgToOffscreen' = bgToOffscreen \ {msg}
        /\ evalQueueGen' = evalQueueGen + 1
        /\ evalQueue' = <<>>
        /\ \/ /\ sessionRuntime' = "Initialized"
              /\ sessionType' \in SessionTypes
              /\ offscreenToBg' = offscreenToBg \cup
                  {[type |-> "InitResponse",
                    success |-> TRUE,
                    sessionType |-> sessionType',
                    source |-> "config"]}
           \/ /\ sessionRuntime' = "Uninitialized"
              /\ sessionType' = "None"
              /\ offscreenToBg' = offscreenToBg \cup
                  {[type |-> "InitResponse",
                    success |-> FALSE,
                    sessionType |-> "None",
                    source |-> "config"]}
    /\ UNCHANGED <<contentQueue, contentGeneration, contentProcessing, filteringMode,
                   cache, cacheOrder, cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionInitLocked,
                   evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, bgToContent,
                   currentConfig>>

-----------------------------------------------------------------------------
(* Config Change Actions *)

\* User changes config (e.g., via Options page).
\* MEMORY ISSUE: ConfigChange clears cache and content queue, but does NOT
\* drain in-flight messages or waiting fibers. Orphaned responses from
\* pre-change evaluations still arrive and get cached under the new config.
ConfigChange ==
    /\ \E enabled \in BOOLEAN :
        /\ currentConfig' = [enabled |-> enabled]
        /\ IF enabled
           THEN /\ cache' = <<>>
                /\ cacheOrder' = <<>>
                /\ Cardinality(bgToOffscreen) < MaxInFlight
                /\ bgToOffscreen' = bgToOffscreen \cup
                    {[type |-> "ReinitRequest"]}
                /\ filteringMode' = "Enabled"
                /\ UNCHANGED <<contentQueue, contentGeneration>>
           ELSE /\ cache' = <<>>
                /\ cacheOrder' = <<>>
                /\ filteringMode' = "Disabled"
                /\ contentQueue' = <<>>
                /\ contentGeneration' = contentGeneration + 1
                /\ UNCHANGED bgToOffscreen
    /\ UNCHANGED <<contentProcessing,
                   cacheLocked, offscreenExists, offscreenLocked, bgWaitingFibers,
                   sessionRuntime, sessionType, sessionInitLocked,
                   evalQueue, evalQueueGen, evalQueueLocked, evalInProgress, clonedSessions,
                   contentToBg, offscreenToBg, bgToContent>>

-----------------------------------------------------------------------------
(* Next-state relation *)

Next ==
    \/ \E tid \in TweetIds : DiscoverTweet(tid)
    \/ SendEvaluateRequest
    \/ ReceiveEvaluateResponse
    \/ SendInitRequest
    \/ BgHandleInitRequest
    \/ BgHandleEvaluateRequest_CacheHit
    \/ BgHandleEvaluateRequest_CacheMiss
    \/ BgForwardEvaluateResponse
    \/ BgForwardInitResponse
    \/ BgConsumeReinitResponse
    \/ EnsureOffscreenDocument
    \/ OffscreenHandleInitRequest
    \/ OffscreenEnqueueEvaluation
    \/ OffscreenProcessEvaluation
    \/ OffscreenCompleteEvaluation
    \/ OffscreenHandleReinit
    \/ ConfigChange

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* State constraint for finite model checking *)
\* Bounds unbounded variables to keep state space finite for TLC.
\* These are NOT invariants; they limit exploration depth.
StateConstraint ==
    /\ bgWaitingFibers <= MaxInFlight + 1
    /\ Cardinality(offscreenToBg) <= MaxInFlight + 1
    /\ Cardinality(bgToContent) <= MaxInFlight + 1
    /\ contentGeneration <= 2
    /\ evalQueueGen <= 2

-----------------------------------------------------------------------------
(* Safety Properties *)

\* Cache never exceeds maximum size
CacheBounded == CacheSize <= MaxCacheSize

\* Evaluation queue never exceeds maximum length
EvalQueueBounded == Len(evalQueue) <= MaxQueueLen

\* Cache entries are consistent with LRU order
CacheOrderConsistency ==
    \A t \in DOMAIN cache : SeqContains(cacheOrder, t)

\* Session type is "None" iff session is uninitialized
SessionTypeConsistency ==
    (sessionRuntime = "Uninitialized") <=> (sessionType = "None")

\* When filtering is disabled, no evaluation requests are sent
DisabledNoRequests ==
    filteringMode = "Disabled" => contentQueue = <<>>

-----------------------------------------------------------------------------
(* Memory Safety Properties *)

\* CRITICAL INVARIANT: Total memory pressure must stay within budget.
\* This invariant will FAIL in TLC, revealing the accumulation pattern.
MemoryBudgetRespected ==
    TotalMemoryPressure <= MaxMemoryBudget

\* All message channels must be bounded
ChannelsBounded ==
    /\ Cardinality(contentToBg) <= MaxInFlight
    /\ Cardinality(bgToOffscreen) <= MaxInFlight
    /\ Cardinality(offscreenToBg) <= MaxInFlight
    /\ Cardinality(bgToContent) <= MaxInFlight

\* Cloned sessions must be bounded (at most 1 per in-flight evaluation)
ClonedSessionsBounded ==
    clonedSessions <= 1

\* Background waiting fibers must be bounded
BgFibersBounded ==
    bgWaitingFibers <= MaxInFlight

\* ISSUE DETECTOR: No orphaned messages after config disable.
\* When filtering is disabled, no evaluate messages should remain in channels.
\* This invariant MAY FAIL because in-flight messages are not drained on disable.
NoOrphanedMessagesOnDisable ==
    filteringMode = "Disabled" =>
        /\ ~(\E msg \in contentToBg : msg.type = "EvaluateRequest")
        /\ ~(\E msg \in bgToOffscreen : msg.type = "EvaluateRequest")

\* ISSUE DETECTOR: Content queue should not hold items for tweets already
\* evaluated (stale DOM references).
\* In real code, TweetData.element pins DOM nodes in memory even after
\* they scroll off-screen.
NoStaleQueueEntries ==
    \A i \in 1..Len(contentQueue) :
        contentQueue[i] \notin DOMAIN cache

\* Combined resource pressure: content queue + in-flight messages + eval queue.
\* This measures the "pipeline depth" - how many tweets are simultaneously
\* consuming memory across all three components.
PipelineDepth ==
      Len(contentQueue)
    + Cardinality({msg \in contentToBg : msg.type = "EvaluateRequest"})
    + Cardinality({msg \in bgToOffscreen : msg.type = "EvaluateRequest"})
    + Len(evalQueue)
    + (IF evalInProgress /= "None" THEN 1 ELSE 0)
    + Cardinality({msg \in offscreenToBg : msg.type = "EvaluateResponse"})
    + Cardinality({msg \in bgToContent : msg.type = "EvaluateResponse"})

PipelineDepthBounded ==
    PipelineDepth <= MaxQueueLen + MaxInFlight

-----------------------------------------------------------------------------
(* Liveness Properties (under fairness) *)

\* Every enqueued tweet eventually gets a response
EventualResponse ==
    \A tid \in TweetIds :
        (tid \in {contentQueue[i] : i \in 1..Len(contentQueue)})
            ~> (\E msg \in bgToContent :
                    msg.type = "EvaluateResponse" /\ msg.tweetId = tid)

Fairness ==
    /\ WF_vars(SendEvaluateRequest)
    /\ WF_vars(ReceiveEvaluateResponse)
    /\ WF_vars(BgHandleEvaluateRequest_CacheMiss)
    /\ WF_vars(BgForwardEvaluateResponse)
    /\ WF_vars(BgForwardInitResponse)
    /\ WF_vars(OffscreenEnqueueEvaluation)
    /\ WF_vars(OffscreenProcessEvaluation)
    /\ WF_vars(OffscreenCompleteEvaluation)

LiveSpec == Spec /\ Fairness

=============================================================================
