--[[--
Novita AI API Handler (community set — M1, model_management_strategy.md
"End-state REVISION 2"). Plain OpenAI-compatible chat wire; capabilities come
from family fallbacks and the derived layer ("Test this provider"), not
curated lists.

@module novita
]]

local OpenAICompatibleHandler = require("koassistant_api.openai_compatible")

local Handler = OpenAICompatibleHandler:new()

function Handler:getProviderName()
    return "Novita AI"
end

function Handler:getProviderKey()
    return "novita"
end

-- Shared OpenAI-shaped transformer (incl. tool-call extraction) — same parser
-- the custom-provider path uses; no per-provider parser for the community set.
function Handler:getResponseParserKey()
    return "openai"
end

return Handler
