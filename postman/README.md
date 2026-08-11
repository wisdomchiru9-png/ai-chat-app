# Postman usage

1. Open Postman → **Import** → select both files in this folder:
   - `AI Chat App.postman_collection.json`
   - `AI Chat Dev.postman_environment.json`

2. Top-right: choose the **AI Chat Dev** environment.

3. Run the folders in order (0 → 1 → 2 → 3 → 4):
   - **0 — Health** → confirms backend is up
   - **1 — Sentiment** → two positive/negative checks
   - **2 — Sessions** → creates a session and stores its id in a collection variable, renames it, fetches detail
   - **3 — Chat (persisted)** → runs 2 chat turns using that session id, fetches messages to confirm persistence, then deletes the session
   - **4 — Evaluator (Node.js)** → hits the Node LLM evaluator service; needs both services running

4. (Optional) Open the **Runner**, select the collection, check **Save responses** to generate a report showing pass/fail per endpoint — perfect for a resume screenshot.
