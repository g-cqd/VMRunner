/// Signed files the vendors publish, captured on 2026-10-21 whole and byte for byte, each ending in the line break the vendor's
/// file ends in. Their signatures were made by the keys in `PGP.PinnedKeys`. No test touches the network.
enum SignedVendorFiles {
    /// `SHA256SUMS` of `/debian-cd/current/arm64/iso-cd/`.
    static let debianChecksums = """
        6e93fa1759bd9d4b0fc11e938987de6967ee7de5297dac1be27c3a75cc17024b  debian-13.7.0-arm64-netinst.iso

        """

    /// `SHA256SUMS.sign`: an armored detached signature, SHA-256.
    static let debianSignature = """
        -----BEGIN PGP SIGNATURE-----

        iQIzBAABCAAdFiEE35ucSeqpKYQyWJ122ofoDWKUvpsFAmqle+EACgkQ2ofoDWKU
        vpuv9Q//ZMq63JzMApgzeZv2zj064xvpSnEOU0psQWv/4XWytrhV/uYYV5QaRpUh
        KMHxOXNJ7CPoEAZjEcMwZVwZk/DC6y1BUjeZ8RPw/eIpEK5F0L2nwl/zTlXY6eoz
        Hz7Cee0j4ra89DRqsZyhTMHUOJbzAhLbDEk+0bHynwOlc1IIWnnt5lpEehpTNynO
        S46Fs1NfSgmhfZWl6faKEj/vSyEjX2N9WUpIBp9oudb968qqcYPAlEDtzXyYdPmx
        0B8MDcfbXbDp5kGvh0bt4ISCfKxH+cfRgX961mqa/+ZijfOUt+w/yKsoKy6mN/QJ
        L/bTlIxerjqWPquKfzQONHOI1qXPVevxp4ZWknOgs60Goy85sZxXpUMHkShbfWqQ
        gY3TcoLqxLBmTBpBAtJPT5tl6A5zHMUOQg4JLnoM56c3PhZJtgwPrhwjlMJWLl+e
        4y12g3qb978nlSvKmGwloxwUUbG9olCafFNAld/J5dZJ2zAVQI22wdjAW8UGqeS9
        I5GHbARxrB+YwZtRYp4ZNk2sseXTY2JENB2FAuWzoNUmFOKtHEC0f2bMKghRtPl3
        zjysGHvYNQ/4/yxsP9fbgSfMPIPe0KF6AYL3NHgyRMEtZs9Au/XVQjOkTuKAIffA
        fZ1REN59BXK0Y8YbkMwHTPLRHtKUs8PPb5UPPUNWrjX9O0Z279E=
        =clAV
        -----END PGP SIGNATURE-----

        """

    /// `SHA256SUMS` of `/ubuntu/releases/26.04/release/`.
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

    /// `SHA256SUMS.gpg`: an armored detached signature, SHA-512.
    static let ubuntuSignature = """
        -----BEGIN PGP SIGNATURE-----

        iQIzBAABCgAdFiEEhDk43yKNIvezdCvA2Uqj8O/iEJIFAmqQq5QACgkQ2Uqj8O/i
        EJLHgxAAt/rXeVr0WzpdHqn/OmkDm+zttTpGJ1OSDV0zKOZ+faUyTg9FwHIQcrjj
        w/YF4ZRBJIcUzWbNrAIJY7qlplVfn1/j0yM3Qd/9tAX3dp7Z3JG+UzLQAk1DJ7Da
        vvOpjtKt10S5oSqNbIiqveGIFw9AaoYtvBLfpPTlLfZ6hRdg0MZZWItAPz2PMnfQ
        Jl1BNyhNL38zzcjoERU+U2SbQRjRoIXNp/sm2cO0HGgPdc28bmeLaJHitmM8fEAe
        wK5MipKV3Bx13dM1FuUPE0aajc5Lyy9H02ZYIc2PlwieUBoThrowc829kZ1MCShR
        L7pqW5Fl8JW3JqBMGbj/JIFbpvqbXKjYGGieo6UerapDdpt/oZjeIMYw1A6iE3v7
        6ViJd6fTwDh6zmOiDv6DzfAp5L9/tlfJ0wXo519br1kUeP1EHJtGr0vl17NUhlU4
        SxOBHKw6EXfQH18PzqIXGrRJt4Q7X3651ozd0LilXvauehIreMKXp7/utFUNp7O7
        vj++3FxPu/OgnI6vEIVg10R81UgPgtbggViLHLqqgNrXoBslVUKD8tKX6tbFMOzn
        Tiv91WeRz+mUspM5fNWmpeTzAdkk2eZH8mo4C2m82Kbzxl4nseDIqCBBkaKsNGoO
        j7PwBhJrgI5Q0Kdb4qCsLkZ+5gp/EgI8QvyOgWG7+6o6jdd7E0I=
        =Cwmu
        -----END PGP SIGNATURE-----

        """

    /// `Fedora-Server-44-1.7-aarch64-CHECKSUM`: a cleartext-signed message, SHA-256.
    static let fedoraChecksum = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA256

        # Fedora-Server-dvd-aarch64-44-1.7.iso: 3662544896 bytes
        SHA256 (Fedora-Server-dvd-aarch64-44-1.7.iso) = ba8372682294d0d76f79427cae1273d36891b192ac9bf0f0f9de4e97a7cbe218
        # Fedora-Server-netinst-aarch64-44-1.7.iso: 1257783296 bytes
        SHA256 (Fedora-Server-netinst-aarch64-44-1.7.iso) = a93ebd0322cda5a439039710b727ac1899a06e1c11876cfdf7f27c25b8262cc3
        -----BEGIN PGP SIGNATURE-----

        iQIzBAEBCAAdFiEENvYS3PJ/fRpIqDXk2/z3HG2fkKYFAmnrjKUACgkQ2/z3HG2f
        kKYaUg/+LsGHBdNHIV4sS/YpleISDPhsxM5Gs/QmhTru758e9A5yTSErEVth4j9K
        BpwC/LhMv0+KzNnkWfV7WCgROcgb/TGuYxSlIssznFSpqPtUukpDJ6Oc5vdUtgdi
        UvY4Zq+1iJC+Xn97RiU0BFBY04wgHy0MCUB09BFxJWsTGXDZ6Y/2FTLQuxiQkCN7
        WgWDNBouzkvzCf6ZPDdjdoigZr15ddfHl/jDn6KV4HZmTyzLYxBEv1PT5J83nINJ
        SDJNeLuMhg8Z+kRR1VxrwJD3R1k6iY1N9iOiBbJnj24ms9YF1aE+RfhvO2vnYYCX
        avgaB5cBxFWg6AASqO55we61800Ode1r7MXzDh8lV8pOqiV2oDBvaFev/lFz16u7
        Pp2WwVwo8+5cssTnUjBl6RdwoYcZxpWDeuZqL2V7paUPdyp7dQbb1DHtYnhn91vF
        Eq+SFEuORAr5calmIr7FEMM+fLfzRsPH/zFmFngM91AiklVnaLJ/jPSBFA8bNvom
        bm/RL1ir5KpONghY1wYJ1HIG5BytjwBXwLt2Uv6M2lxOD2CdVZOO4EAhs8rDDqsN
        5da1yYU7fKmz23IYVQYoHI3JC207S2frrhzqb9GL9XE3b3UiRXfnLpa1XkwXWiLp
        p0vPVTfl0t31pBYt9Ek9R4nJVHv8ktesXRt4yPlyIstSZmr8GXM=
        =K96R
        -----END PGP SIGNATURE-----

        """

    /// `alpine-virt-3.24.2-aarch64.iso.asc`: an armored detached signature over the ISO itself, SHA-512.
    static let alpineSignature = """
        -----BEGIN PGP SIGNATURE-----

        iQIzBAABCgAdFiEEBILYQCL1LfHE581DKTrNCQfZSVoFAmqsSdQACgkQKTrNCQfZ
        SVp8hRAAxy39KyM+sFPbjIpTnQ/9tx+WWDIJ94ozeMxRi2fSTK6I1GavOQ0N7G9b
        wCSG5OSbRc1lzDjtUadXXJPQzVng5u1px+lcz3fW3y5kS1kAt33pN9VKoy1tXf2Z
        fChAR0asAXD9poKAc1D9DizpXIZ765vTp/lh/zn/HpI8FG2vDklla9K2VU8Nwfcp
        TDAOa6xL3YhqpTgemxoKKIo7QXHRV0NI+3gY9Hx29lTKEHGYNp1gm/PAaZQxuPS6
        1M5KVLYRHuo4OE+huBL8Qz/FAkGlU7AP0Pma05z7mavNUBk07oYGIuliRD5rShLf
        yd3LzRbKeAEfZbvZrRq/TcA8rhZV+XH6OmC3qKbTHymBirjwAgSBRUwEwI+LDDWq
        3ylmIK5KOvJOWqGMg+cEAPRZPCVb7d0ICk1SMlrm6V4YSaqIhw07m50Zpw914Ocf
        QSx9/hMmBT1q2ZyEc9XhPmvudIyEjVENNS1MbxP648KuYMcfAxK9/uL2zqKWXfCN
        1cUBudm5j0t6D6VzKD2wl97iPOACDPpS3PjrLuxpXsO4O+qdviapExZViGgVZ4mu
        FQEpcW5oaNZrO0LGcMbU/ItIoBXItxHiSfJcAAJNkkU1tqGVIrkIJlTKqcOwBiex
        kXs4xlLtWbm2nPNhitEYreVYhGYQ6sWWTMLUcZbOmITEcrkbCkA=
        =vRbx
        -----END PGP SIGNATURE-----

        """
}
