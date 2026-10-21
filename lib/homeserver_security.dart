/// Reject insecure or credential-bearing homeserver URLs before password login.
bool isSecureHomeserver(Uri? url) =>
    url != null &&
    url.scheme == 'https' &&
    url.host.isNotEmpty &&
    url.userInfo.isEmpty &&
    !url.hasQuery &&
    !url.hasFragment;
