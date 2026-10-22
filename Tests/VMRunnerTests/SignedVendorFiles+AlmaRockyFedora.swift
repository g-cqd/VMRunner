/// More signed files the vendors publish, captured on 2026-10-22 whole and byte for byte, each ending in the line break the
/// vendor's file ends in, like those in `PGPFixtures.swift`. Their signatures were made by the keys in `PGP.PinnedKeys`. No test
/// touches the network.
extension SignedVendorFiles {
    /// `CHECKSUM` of `/almalinux/10/isos/aarch64/` on repo.almalinux.org: a cleartext-signed message, SHA-256.
    static let almaLinuxChecksum = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA256

        # AlmaLinux-10.2-aarch64-boot.iso: 1128263680 bytes
        SHA256 (AlmaLinux-10.2-aarch64-boot.iso) = 20807d65338627a0afa3d5fbd3bee222115d66ce34ac1e4647b0af8fc6c4aa23
        # AlmaLinux-10-latest-aarch64-boot.iso: 1128263680 bytes
        SHA256 (AlmaLinux-10-latest-aarch64-boot.iso) = 20807d65338627a0afa3d5fbd3bee222115d66ce34ac1e4647b0af8fc6c4aa23
        # AlmaLinux-10.2-aarch64-dvd.iso: 9588244480 bytes
        SHA256 (AlmaLinux-10.2-aarch64-dvd.iso) = bc3790b1200254790e03f1d941162a9f9082d46dcdff841b83f348501625b29e
        # AlmaLinux-10-latest-aarch64-dvd.iso: 9588244480 bytes
        SHA256 (AlmaLinux-10-latest-aarch64-dvd.iso) = bc3790b1200254790e03f1d941162a9f9082d46dcdff841b83f348501625b29e
        # AlmaLinux-10.2-aarch64-minimal.iso: 1657339904 bytes
        SHA256 (AlmaLinux-10.2-aarch64-minimal.iso) = ca5dd9b7e1193de5881df850a93b611c6ba0ba8c5860f54ee822c53585b3014d
        # AlmaLinux-10-latest-aarch64-minimal.iso: 1657339904 bytes
        SHA256 (AlmaLinux-10-latest-aarch64-minimal.iso) = ca5dd9b7e1193de5881df850a93b611c6ba0ba8c5860f54ee822c53585b3014d
        -----BEGIN PGP SIGNATURE-----

        iQIzBAEBCAAdFiEE7m23uY9b9e3Z2g3l3uXBHMKh5XIFAmoSHHUACgkQ3uXBHMKh
        5XIN5Q//dIGt3tRw6WybeZDKjc2oTThfKljNDkDEbadI2Klp0b2A2TUt+I7NMdA1
        Zo0DTuTCxu8s0OOaXXW9eOIXripp3fBdelCECiBeXK4Q07wWU+ARdASga5DvUqga
        rJUyGSd+1+2OMex8gWfTXHX+W7lRKF/QfLS2hR+56CLrMOf00dxwfQWje8Ax+c6V
        8aidTNueCH+zGDnTUWmUyXEooRGpxUNqZ5XR8vE0mUmz955pvQvFyLpiJxTILmhk
        iynYibGqquKgiTsikDllK3MgnlaRsEfYpaTPMhMWZWxvJ5eCdFvKpixvZ4Ib5wmg
        w6Fk6SWWC73pfmlYr6oyI+sBhMA3Ellau0mA1LD7ywGCgDrGoHSs3qCNUrOT530u
        emEsp7YtRZ2JIJIMktB2W2lhAWtDxSki08C2CQ0rNy+YyEYjCfSFr8Zs8zk/QRcn
        Ton9FGNAu95L+CJa4gW1QhG51UqgEXKDN9sBjTYjJgM5ws+q8GhR6hj0zsBp8ttD
        P178yCbEMpFn5GIPV8lNTTBTFiYviTuMCSmSSwBBgxOVZnnyUWoSyT1jZ0ZajNgY
        XItHhNgQTIrOWMIlQpAY84i3wZLCGf3EFDk35no17ztyhFEYZ6a39XzvHcv6MdOX
        PCilP2jqlrDi/xPjKpDOvzlTVdg1J2642hP8tYGJqOHndn+tU8k=
        =4GLv
        -----END PGP SIGNATURE-----

        """

    /// `CHECKSUM` of `/pub/rocky/10/isos/aarch64/` on download.rockylinux.org.
    static let rockyLinuxChecksum = """
        # Rocky-10.2-aarch64-boot.iso: 1120931840 bytes
        SHA256 (Rocky-10.2-aarch64-boot.iso) = 33c2d3dfd5f947b3201478180b549bb2995bd9573c2776b384e5ec1dd47326c0
        # Rocky-10.2-aarch64-dvd1.iso: 9659678720 bytes
        SHA256 (Rocky-10.2-aarch64-dvd1.iso) = 3b8253987604df1bc5e1c33c838ff3ee9ce4a8f02ed9e27e300ecff58c0c9588
        # Rocky-10.2-aarch64-minimal.iso: 2397044736 bytes
        SHA256 (Rocky-10.2-aarch64-minimal.iso) = 1d1c21199df32f6d17eedb4f713ee0d089b49294401a364b640fcf4ffab45f35
        # Rocky-10-latest-aarch64-boot.iso: 1120931840 bytes
        SHA256 (Rocky-10-latest-aarch64-boot.iso) = 33c2d3dfd5f947b3201478180b549bb2995bd9573c2776b384e5ec1dd47326c0
        # Rocky-10-latest-aarch64-dvd.iso: 9659678720 bytes
        SHA256 (Rocky-10-latest-aarch64-dvd.iso) = 3b8253987604df1bc5e1c33c838ff3ee9ce4a8f02ed9e27e300ecff58c0c9588
        # Rocky-10-latest-aarch64-minimal.iso: 2397044736 bytes
        SHA256 (Rocky-10-latest-aarch64-minimal.iso) = 1d1c21199df32f6d17eedb4f713ee0d089b49294401a364b640fcf4ffab45f35

        """

    /// `CHECKSUM.asc`: an armored detached signature over `rockyLinuxChecksum`, SHA-256.
    static let rockyLinuxSignature = """
        -----BEGIN PGP SIGNATURE-----

        iQIzBAABCAAdFiEE/CJoWcCGC/DduVsIWxBsc2/t/IUFAmoZCzYACgkQWxBsc2/t
        /IUYTg/+Na9nlLa/UVRk8cX1/gAoSEL76oh7C8tr5Y+rhA7pjT37hk/Ctg2Mvrv4
        Yt4LmeckUFXHJuCX3yQE2z6dEoAMBjo7BEwWUh+YmSaHjniL5SYiublrw2VaMqZl
        3jpYGbAWAW8/sdYYnO4Cm5FnRNMFBx6WxI6oo2yQmeG+Wg0jZmUPja+Hffts//PU
        U1fcAZT3HvmA1M5YZRvNOWbcJxO1MeJt97cPztbkr8oTM5pyFI0gEMmz1ER429q0
        kN+Wx2Ue91Al2pLiYribXUHwsvVZFs5yO/63QcjzmhuDtXN6hI2hAtXarVc8oog8
        8oeFQo1ZlIeUj0TdF+C5iuEiBuXkpp8ckmXARcWdc2pANbKtAuT76AGNWCJrtp89
        B38aJ4L6iMc791ISGzrMa+k7nE6nq4QWor+8vPNgiXGR80mspcPypH6K8map8OCd
        /yWv2pPiFe6F7XnOdwwHeMBqMn6/OIX2jt2VTOXyvsEH0RPxsV6p40o+pln6J9c/
        Cf6XsXvHF/zCmKOS8i1tXS0p5lyZSYCcBycs+X9bRmcYTwdRZiBPGK7gnVxe+I1X
        Tesl2NtuJNP8Tl3S4TKh1FWatoMhnCAKtQBf4ueN+NaA7v1krlkREA0KgJx/aV8p
        Wu8eS2O6pDMTwRBkj/uN6iW1Hrps2Qx5SewLyHUmoMGhptY90d4=
        =j8PH
        -----END PGP SIGNATURE-----

        """
}
