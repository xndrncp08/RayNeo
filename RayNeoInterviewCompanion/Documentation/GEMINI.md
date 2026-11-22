# RayPrompt — Gemini Flash (cloud, optional)

Off by default. The app never calls Gemini unless you (1) turn on **Settings › AI › Allow Gemini**, (2) save an API key and (3) choose **AI model › Gemini Flash (cloud)**. **Auto** stays on-device and never picks Gemini.

## What is sent to Google

Per question: the answer instructions for its category, the question, matching knowledge-base notes, and for follow-ups the previous question and answer.
Audio is never sent. Full raw transcripts are not uploaded, but detected questions are derived from them. The separate context-sharing setting allows relevant personal memory and recent conversation to enter Gemini prompts. Review that setting before enabling cloud generation.
On the free tier, Google may use submitted content to improve its products (pricing page, November 2026).

## Free-tier setup (no billing)

1. Open Google AI Studio and create an API key in a project **with no billing account attached**. Without billing, usage cannot be charged; over the limit, Gemini returns `429 RESOURCE_EXHAUSTED`.
2. Recommended: in Google Cloud Console › Credentials, restrict the key to:
   - *iOS apps*, bundle ID `com.derrancap.RayNeoInterviewCompanion` (the app sends `X-Ios-Bundle-Identifier`);
   - *API restriction:* Generative Language API.
3. In the app (Settings › Gemini Flash): turn on Allow Gemini, paste the key, tap **Save key**, then **Test Gemini Connection**. It first runs `models.get`, which must list `generateContent`, then one minimal streamed request. It reports the result, HTTP status, model, first-token latency, finish reason and response. The key is never shown.
4. Choose the model. All three were listed as free-tier eligible on the pricing page (November 2026):
   - `gemini-3.5-flash-lite` (default)
   - `gemini-3.6-flash`
   - `gemini-3.8-flash`

   Free-tier RPM/RPD limits are shown in your AI Studio dashboard, not on the docs page. Recheck eligibility before relying on it.

## How it is built

- **API:** official REST endpoint `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:streamGenerateContent?alt=sse`, with the key in the `x-goog-api-key` header (never in the URL). Confirmed current in the API reference on 2026-11-20.
- **Request:** sends `maxOutputTokens` and no temperature (Gemini 3.6+ ignores it). Parts marked `thought` are dropped.
- **Key storage:** the Keychain (`WhenUnlockedThisDeviceOnly`). It is never stored in settings, source, or logs.
- **Errors:**

  | Response | Error |
  |---|---|
  | 429 | rate limited |
  | 401/403 | key rejected |
  | 404 | model unavailable |
  | 400 | bad request |
  | 5xx | server |
  | URL errors | offline / timed out (20 s) |

- **Fallback** (on by default, can be turned off): if Gemini fails **before producing any text**, the same question is answered by Apple on-device. A 400 is not hidden by fallback. An answer is never spliced from two models.
- **Shown in the app:** which provider answered, plus the network latency.

## Limits and alternatives

- A user-entered key is personal-use only. A distributed app must not embed a key. For that, use **Firebase AI Logic** with **App Check** (Google's recommended client protection) or a backend proxy. This build does not include the Firebase SDK; it would need a Firebase project and `GoogleService-Info.plist`.
- Cloud latency has **not** been measured on the iPhone yet. Compare with the evaluation (below) before choosing a default.

## Benchmark Apple vs Gemini (on the iPhone)

Settings › Answer evaluation:
1. Run with Apple On-Device.
2. Switch the AI model to Gemini Flash and run again.

The **Comparison** section shows both summaries: accuracy, non-answer rate, median/p95 latency, first complete sentence, failure rate and 429 rate. Keep Apple as the default unless Gemini is clearly better on these real measurements.
