module Shared.Messaging.Constants where

-- Message type strings

initRequest :: String
initRequest = "INIT_REQUEST"

initResponse :: String
initResponse = "INIT_RESPONSE"

evaluateRequest :: String
evaluateRequest = "EVALUATE_REQUEST"

evaluateResponse :: String
evaluateResponse = "EVALUATE_RESPONSE"

cacheCheckRequest :: String
cacheCheckRequest = "CACHE_CHECK_REQUEST"

cacheCheckResponse :: String
cacheCheckResponse = "CACHE_CHECK_RESPONSE"

configChanged :: String
configChanged = "CONFIG_CHANGED"

sessionStatusRequest :: String
sessionStatusRequest = "SESSION_STATUS_REQUEST"

sessionStatusResponse :: String
sessionStatusResponse = "SESSION_STATUS_RESPONSE"

reinitRequest :: String
reinitRequest = "REINIT_REQUEST"

errorType :: String
errorType = "ERROR"

-- Timeouts (milliseconds)

timeoutInitRequest :: Int
timeoutInitRequest = 30000

timeoutEvaluateRequest :: Int
timeoutEvaluateRequest = 15000

timeoutCacheCheckRequest :: Int
timeoutCacheCheckRequest = 1000

timeoutSessionStatusRequest :: Int
timeoutSessionStatusRequest = 2000

timeoutImageFetch :: Int
timeoutImageFetch = 5000

timeoutPrompt :: Int
timeoutPrompt = 10000

-- Offscreen document configuration

offscreenDocumentPath :: String
offscreenDocumentPath = "offscreen/index.html"

offscreenReason :: String
offscreenReason = "WORKERS"

offscreenJustification :: String
offscreenJustification = "Run Gemini Nano AI processing in a Window context"
