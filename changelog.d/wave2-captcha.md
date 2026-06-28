### Features

- **`ctx.verifyCaptcha(provider, token) !CaptchaResult`** (#140) — verify CAPTCHA tokens from reCAPTCHA v2/v3, hCaptcha, and Cloudflare Turnstile via `ctx.http()`. Configure with `App(.{ .captcha = .{ .provider = .recaptcha_v3, .secret = "..." } })`; dev-bypass (returns `ok=true` without a network call) when secret is empty.
