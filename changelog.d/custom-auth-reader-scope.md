### Performance
- Authenticated custom routes release their auth/tenant lookup reader before route guards and handlers run, so the handler's own reads no longer hold a second reader for the request's duration. Authorization and request-owned identity/tenant data are unchanged.
