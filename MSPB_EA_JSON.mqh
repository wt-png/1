#ifndef MSPB_EA_JSON_MQH
#define MSPB_EA_JSON_MQH

// -----------------------------------------
// Lightweight JSON helpers (read-only)
// Designed for the Telegram Bot API getUpdates response.
// These are NOT a full JSON parser.  They handle the flat
// "key":integer  and  "key":"string"  patterns produced by
// the Telegram Bot API.  All searches are case-sensitive and
// find the FIRST occurrence of the key at or after startPos.
// -----------------------------------------

// Sentinel returned by JsonGetLong when the key is not found.
#define JSON_LONG_NOT_FOUND (-9223372036854775807-1) // LLONG_MIN

// Return the integer value of the first "key": <digits> at or after
// startPos.  Returns JSON_LONG_NOT_FOUND on failure.
long JsonGetLong(const string json, const string key, const int startPos=0)
{
   string needle = "\"" + key + "\":";
   int p = StringFind(json, needle, startPos);
   if(p < 0) return JSON_LONG_NOT_FOUND;
   p += StringLen(needle);
   // skip optional whitespace
   while(p < StringLen(json) && StringGetCharacter(json, p) == ' ') p++;
   bool negative = false;
   if(p < StringLen(json) && StringGetCharacter(json, p) == '-') { negative = true; p++; }
   int pEnd = p;
   while(pEnd < StringLen(json))
   {
      int c = StringGetCharacter(json, pEnd);
      if(c < '0' || c > '9') break;
      pEnd++;
   }
   if(pEnd == p) return JSON_LONG_NOT_FOUND;
   long v = StringToInteger(StringSubstr(json, p, pEnd - p));
   return negative ? -v : v;
}

// Return the character position just past the numeric value of
// "key": <digits>, so that the caller can continue scanning forward.
// Returns -1 when the key is not found.
int JsonGetLongEnd(const string json, const string key, const int startPos=0)
{
   string needle = "\"" + key + "\":";
   int p = StringFind(json, needle, startPos);
   if(p < 0) return -1;
   p += StringLen(needle);
   while(p < StringLen(json) && StringGetCharacter(json, p) == ' ') p++;
   if(p < StringLen(json) && StringGetCharacter(json, p) == '-') p++;
   while(p < StringLen(json) && StringGetCharacter(json, p) >= '0' && StringGetCharacter(json, p) <= '9') p++;
   return p;
}

// Return the string value of the first "key":"<value>" at or after
// startPos.  Handles backslash-escaped quotes inside the value.
// Returns "" both when the key is absent and when the value is an
// empty string — callers that need to distinguish these cases should
// call JsonHasKey() first.
string JsonGetString(const string json, const string key, const int startPos=0)
{
   string needle = "\"" + key + "\":\"";
   int p = StringFind(json, needle, startPos);
   if(p < 0) return "";
   p += StringLen(needle);
   int pEnd = p;
   while(pEnd < StringLen(json))
   {
      int ch = StringGetCharacter(json, pEnd);
      if(ch == '"' && (pEnd == 0 || StringGetCharacter(json, pEnd - 1) != '\\')) break;
      pEnd++;
   }
   return StringSubstr(json, p, pEnd - p);
}

// Return true when "key": (or "key":") is present at or after startPos.
bool JsonHasKey(const string json, const string key, const int startPos=0)
{
   return StringFind(json, "\"" + key + "\":", startPos) >= 0;
}

#endif // MSPB_EA_JSON_MQH
