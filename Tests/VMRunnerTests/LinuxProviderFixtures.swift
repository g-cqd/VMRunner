// swiftlint:disable line_length
// The captured rows keep the vendors' own line lengths, so the fixtures stay verbatim.

/// Files the vendors publish, captured on 2026-10-21 and trimmed to the lines that matter. No test touches the network.
enum VendorFiles {
    /// `alpine-virt-3.24.2-aarch64.iso.sha256`, whole.
    static let alpineChecksum = "a57ba668b5f6b17a670fcf8e799d5d7fe43766ed086d6ce2927b0625bf43dbf6  alpine-virt-3.24.2-aarch64.iso\n"

    /// The `alpine-standard` and `alpine-virt` rows of `/alpine/latest-stable/releases/aarch64/`: three releases and the
    /// 3.24.0 release candidates, each with its signature and checksums.
    static let alpineListing = """
        <html>
        <head><title>Index of /alpine/latest-stable/releases/aarch64/</title></head>
        <body>
        <h1>Index of /alpine/latest-stable/releases/aarch64/</h1><hr><pre><a href="../">../</a>
        <a href="alpine-standard-3.24.0-aarch64.iso">alpine-standard-3.24.0-aarch64.iso</a>                 09-Jun-2026 14:00    375M
        <a href="alpine-standard-3.24.0-aarch64.iso.asc">alpine-standard-3.24.0-aarch64.iso.asc</a>             09-Jun-2026 14:44     833
        <a href="alpine-standard-3.24.0-aarch64.iso.sha256">alpine-standard-3.24.0-aarch64.iso.sha256</a>          09-Jun-2026 14:00     101
        <a href="alpine-standard-3.24.0-aarch64.iso.sha512">alpine-standard-3.24.0-aarch64.iso.sha512</a>          09-Jun-2026 14:00     165
        <a href="alpine-standard-3.24.0_rc1-aarch64.iso">alpine-standard-3.24.0_rc1-aarch64.iso</a>             08-Jun-2026 08:22    375M
        <a href="alpine-standard-3.24.0_rc1-aarch64.iso.sha256">alpine-standard-3.24.0_rc1-aarch64.iso.sha256</a>      08-Jun-2026 08:22     105
        <a href="alpine-standard-3.24.0_rc1-aarch64.iso.sha512">alpine-standard-3.24.0_rc1-aarch64.iso.sha512</a>      08-Jun-2026 08:22     169
        <a href="alpine-standard-3.24.0_rc2-aarch64.iso">alpine-standard-3.24.0_rc2-aarch64.iso</a>             08-Jun-2026 20:51    375M
        <a href="alpine-standard-3.24.0_rc2-aarch64.iso.sha256">alpine-standard-3.24.0_rc2-aarch64.iso.sha256</a>      08-Jun-2026 20:51     105
        <a href="alpine-standard-3.24.0_rc2-aarch64.iso.sha512">alpine-standard-3.24.0_rc2-aarch64.iso.sha512</a>      08-Jun-2026 20:51     169
        <a href="alpine-standard-3.24.1-aarch64.iso">alpine-standard-3.24.1-aarch64.iso</a>                 13-Jun-2026 16:41    375M
        <a href="alpine-standard-3.24.1-aarch64.iso.asc">alpine-standard-3.24.1-aarch64.iso.asc</a>             14-Jun-2026 00:06     833
        <a href="alpine-standard-3.24.1-aarch64.iso.sha256">alpine-standard-3.24.1-aarch64.iso.sha256</a>          13-Jun-2026 16:41     101
        <a href="alpine-standard-3.24.1-aarch64.iso.sha512">alpine-standard-3.24.1-aarch64.iso.sha512</a>          13-Jun-2026 16:41     165
        <a href="alpine-standard-3.24.2-aarch64.iso">alpine-standard-3.24.2-aarch64.iso</a>                 17-Sep-2026 17:34    376M
        <a href="alpine-standard-3.24.2-aarch64.iso.asc">alpine-standard-3.24.2-aarch64.iso.asc</a>             17-Sep-2026 20:13     833
        <a href="alpine-standard-3.24.2-aarch64.iso.sha256">alpine-standard-3.24.2-aarch64.iso.sha256</a>          17-Sep-2026 17:34     101
        <a href="alpine-standard-3.24.2-aarch64.iso.sha512">alpine-standard-3.24.2-aarch64.iso.sha512</a>          17-Sep-2026 17:34     165
        <a href="alpine-virt-3.24.0-aarch64.iso">alpine-virt-3.24.0-aarch64.iso</a>                     09-Jun-2026 14:00     88M
        <a href="alpine-virt-3.24.0-aarch64.iso.asc">alpine-virt-3.24.0-aarch64.iso.asc</a>                 09-Jun-2026 14:44     833
        <a href="alpine-virt-3.24.0-aarch64.iso.sha256">alpine-virt-3.24.0-aarch64.iso.sha256</a>              09-Jun-2026 14:00      97
        <a href="alpine-virt-3.24.0-aarch64.iso.sha512">alpine-virt-3.24.0-aarch64.iso.sha512</a>              09-Jun-2026 14:00     161
        <a href="alpine-virt-3.24.0_rc1-aarch64.iso">alpine-virt-3.24.0_rc1-aarch64.iso</a>                 08-Jun-2026 08:22     88M
        <a href="alpine-virt-3.24.0_rc1-aarch64.iso.sha256">alpine-virt-3.24.0_rc1-aarch64.iso.sha256</a>          08-Jun-2026 08:22     101
        <a href="alpine-virt-3.24.0_rc1-aarch64.iso.sha512">alpine-virt-3.24.0_rc1-aarch64.iso.sha512</a>          08-Jun-2026 08:22     165
        <a href="alpine-virt-3.24.0_rc2-aarch64.iso">alpine-virt-3.24.0_rc2-aarch64.iso</a>                 08-Jun-2026 20:51     88M
        <a href="alpine-virt-3.24.0_rc2-aarch64.iso.sha256">alpine-virt-3.24.0_rc2-aarch64.iso.sha256</a>          08-Jun-2026 20:51     101
        <a href="alpine-virt-3.24.0_rc2-aarch64.iso.sha512">alpine-virt-3.24.0_rc2-aarch64.iso.sha512</a>          08-Jun-2026 20:51     165
        <a href="alpine-virt-3.24.1-aarch64.iso">alpine-virt-3.24.1-aarch64.iso</a>                     13-Jun-2026 16:41     88M
        <a href="alpine-virt-3.24.1-aarch64.iso.asc">alpine-virt-3.24.1-aarch64.iso.asc</a>                 14-Jun-2026 00:06     833
        <a href="alpine-virt-3.24.1-aarch64.iso.sha256">alpine-virt-3.24.1-aarch64.iso.sha256</a>              13-Jun-2026 16:41      97
        <a href="alpine-virt-3.24.1-aarch64.iso.sha512">alpine-virt-3.24.1-aarch64.iso.sha512</a>              13-Jun-2026 16:41     161
        <a href="alpine-virt-3.24.2-aarch64.iso">alpine-virt-3.24.2-aarch64.iso</a>                     17-Sep-2026 17:34     89M
        <a href="alpine-virt-3.24.2-aarch64.iso.asc">alpine-virt-3.24.2-aarch64.iso.asc</a>                 17-Sep-2026 20:13     833
        <a href="alpine-virt-3.24.2-aarch64.iso.sha256">alpine-virt-3.24.2-aarch64.iso.sha256</a>              17-Sep-2026 17:34      97
        <a href="alpine-virt-3.24.2-aarch64.iso.sha512">alpine-virt-3.24.2-aarch64.iso.sha512</a>              17-Sep-2026 17:34     161
        </pre><hr></body>
        </html>
        """

    /// The desktop, server and netboot rows of the 26.04 release directory on `cdimage.ubuntu.com` that concern arm64 and
    /// s390x, in the 26.04 and 26.04.1 builds.
    static let ubuntuListing = """
        <table id="indexlist">
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04-desktop-arm64.iso">ubuntu-26.04-desktop-arm64.iso</a></td><td align="right">2026-04-23 02:06  </td><td align="right">3.9G</td><td>Desktop image for 64-bit ARM (ARMv8/AArch64) computers (standard download)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04-live-server-arm64+largemem.iso">ubuntu-26.04-live-server-arm64+largemem.iso</a></td><td align="right">2026-04-22 11:12  </td><td align="right">2.9G</td><td>&nbsp;</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/list.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04-live-server-arm64+largemem.iso.zsync">ubuntu-26.04-live-server-arm64+largemem.iso.zsync</a></td><td align="right">2026-04-23 15:47  </td><td align="right">5.7M</td><td>&nbsp;</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04-live-server-arm64.iso">ubuntu-26.04-live-server-arm64.iso</a></td><td align="right">2026-04-22 09:25  </td><td align="right">2.9G</td><td>Server install image for 64-bit ARM (ARMv8/AArch64) computers (standard download)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/list.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04-live-server-arm64.iso.zsync">ubuntu-26.04-live-server-arm64.iso.zsync</a></td><td align="right">2026-04-23 15:46  </td><td align="right">5.7M</td><td>Server install image for 64-bit ARM (ARMv8/AArch64) computers (<a href="http://zsync.moria.org.uk/">zsync</a> metafile)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04-live-server-s390x.iso">ubuntu-26.04-live-server-s390x.iso</a></td><td align="right">2026-04-20 18:34  </td><td align="right">734M</td><td>Server install image for IBM System z computers (standard download)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/img.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04-netboot-arm64.tar.gz">ubuntu-26.04-netboot-arm64.tar.gz</a></td><td align="right">2026-04-23 15:46  </td><td align="right">163M</td><td>Netboot tarball for 64-bit ARM (ARMv8/AArch64) computers (filesystem archive)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04.1-desktop-arm64.iso">ubuntu-26.04.1-desktop-arm64.iso</a></td><td align="right">2026-08-26 11:17  </td><td align="right">3.9G</td><td>Desktop image for 64-bit ARM (ARMv8/AArch64) computers (standard download)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04.1-live-server-arm64+largemem.iso">ubuntu-26.04.1-live-server-arm64+largemem.iso</a></td><td align="right">2026-08-26 08:15  </td><td align="right">2.9G</td><td>&nbsp;</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/list.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04.1-live-server-arm64+largemem.iso.zsync">ubuntu-26.04.1-live-server-arm64+largemem.iso.zsync</a></td><td align="right">2026-08-27 21:22  </td><td align="right">5.8M</td><td>&nbsp;</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04.1-live-server-arm64.iso">ubuntu-26.04.1-live-server-arm64.iso</a></td><td align="right">2026-08-26 08:11  </td><td align="right">2.9G</td><td>Server install image for 64-bit ARM (ARMv8/AArch64) computers (standard download)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/list.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04.1-live-server-arm64.iso.zsync">ubuntu-26.04.1-live-server-arm64.iso.zsync</a></td><td align="right">2026-08-27 21:21  </td><td align="right">5.7M</td><td>Server install image for 64-bit ARM (ARMv8/AArch64) computers (<a href="http://zsync.moria.org.uk/">zsync</a> metafile)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/iso.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04.1-live-server-s390x.iso">ubuntu-26.04.1-live-server-s390x.iso</a></td><td align="right">2026-08-26 07:31  </td><td align="right">740M</td><td>Server install image for IBM System z computers (standard download)</td></tr>
        <tr><td valign="top"><img src="../../../../cdicons/img.png" alt="[   ]" width="22" height="22"></td><td><a href="ubuntu-26.04.1-netboot-arm64.tar.gz">ubuntu-26.04.1-netboot-arm64.tar.gz</a></td><td align="right">2026-08-27 21:20  </td><td align="right">163M</td><td>Netboot tarball for 64-bit ARM (ARMv8/AArch64) computers (filesystem archive)</td></tr>
        </table>
        """

    /// `SHA256SUMS` of that directory, whole.
    static let ubuntuChecksums = """
        c2afd538d66fdd77377d03f1ed2ac76a34f1c116baecc9a8170d68f833121f57 *ubuntu-26.04-desktop-arm64.iso
        d31e9b3d01ac0fa8e488d4f8d5a7acfeee869f387674eaedf94335e174155901 *ubuntu-26.04-live-server-arm64+largemem.iso
        c9aa567e6560b2eddae3af03fc686002e35b6fee96f97fd5df3271e846439fdd *ubuntu-26.04-live-server-arm64.iso
        0e9f326f55dcc4244f15336ca1221e6d2f36722a4954fc544570da0a12067c3e *ubuntu-26.04-live-server-ppc64el.iso
        82afc6b53c1009d6359017bc9522858670942746e8522d0d6ec951af828b919e *ubuntu-26.04-live-server-riscv64.iso
        d9da688f07bf7a32eba43ba517ce0d4ad19457163fc1f25ddd0d9c6b9dc29632 *ubuntu-26.04-live-server-s390x.iso
        c8b5d454baf26c6ed3f2a211cdd80183671aed8b67a92817cf5750e02da7f6a6 *ubuntu-26.04-preinstalled-desktop-arm64+raspi.img.xz
        17e3699da18dce8f91cdfef2cf4346d9b5c2d0a30e69fde3d3f0dec92490d1c8 *ubuntu-26.04-preinstalled-server-amd64.img.xz
        10604098a0c4eeb7359e58e12b01badbce8c74b0d53b414e633ba0b047b512cd *ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz
        aaa7431beb07aded27664c11c913a66b1764b54538967dfb8d2b3b34d961dd7e *ubuntu-26.04-preinstalled-server-arm64.img.xz
        42210dc700bd7967e7fe294f60d8ee643b27e5870b8f49a4d710155485258aae *ubuntu-26.04-preinstalled-server-riscv64.img.xz
        9fae7b65ac7be0ebb019987c922f1f1f1aaffb061834eb22e76a5e2a958dd3f6 *ubuntu-26.04-wsl-arm64.wsl
        c54d196489d3c867975fb3bbb72ca52ec2e137456e305481f81096304e4d2517 *ubuntu-26.04.1-desktop-arm64.iso
        a7110f6c5e77e6f9d2dd1504a71c43d92c859fcee842bd0d51ca790e8afb5f21 *ubuntu-26.04.1-desktop-riscv64.iso
        2162508a288569897fd9035a6be206b16af9dee525ada692a43cecc9ae986797 *ubuntu-26.04.1-live-server-arm64+largemem.iso
        af78753c94b924c85c4964c670692a853f7c80299a4064e317edad95462e3168 *ubuntu-26.04.1-live-server-arm64.iso
        3eb24626add663104f416bbdb3ca6ed37eabf8bb9a2308d4c9751d0976094826 *ubuntu-26.04.1-live-server-ppc64el.iso
        c44c0e9343a477e08943a140d21ac903ec891ece5c0a69f7424e198562f9f272 *ubuntu-26.04.1-live-server-riscv64.iso
        3756e8b969f67b59e85104cbabe5e1d86e02feb3835a90f6ea97ace86845b49a *ubuntu-26.04.1-live-server-s390x.iso
        8216f54cc1df2fcf7de37530a7edccdd200abd7dcfbc5d4f0407df7513544d6a *ubuntu-26.04.1-preinstalled-desktop-arm64+raspi.img.xz
        80c3b730202a1b02997950d3b08f519550ae97042be9d318ccb5f01cc56c2137 *ubuntu-26.04.1-preinstalled-server-amd64.img.xz
        d59ef9c6e85b906995501f166d00726ab80b59be7b65cdeac0fa31b996053e13 *ubuntu-26.04.1-preinstalled-server-arm64+raspi.img.xz
        189b1aec3eaf9544a51dba4e6ac3f4d5d24fd1031ed0263fa5ea78f1824934c1 *ubuntu-26.04.1-preinstalled-server-arm64.img.xz
        0fafe15634d3b66c3fcb4df17a5fde0b340d2d663af47e4fb5ffb59b9dddc94a *ubuntu-26.04.1-preinstalled-server-riscv64.img.xz
        c7d893d7ccb291009e6096c5a946937337b6fd4c426f11b6541f6cd2bf894f7d *ubuntu-26.04.1-wsl-arm64.wsl

        """
}
// swiftlint:enable line_length
