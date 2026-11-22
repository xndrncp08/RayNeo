# RayPrompt Code Tutor companion (VS Code)

Optional. Lets a guided walkthrough's **code** blocks advance when your editor contains the step's
expected lines and reports no errors. Without it, code blocks stay until you say "next step" or tap Next.

1. iPhone: Settings › Conversation › **Pair a code editor**. Note the code and `address:port`.
2. VS Code (same Wi-Fi): `code --install-extension` this folder packaged with `vsce`, or run it from the
   Extension Development Host; then run **Code Tutor: Pair with iPhone**.

Privacy: pairing uses an HMAC challenge (the code is never sent). The extension sends the file name, one
true/false per expected line, and the error count. It never sends your source. Messages are not encrypted
(local network only). Lines present are evidence, not proof that the code is correct.
