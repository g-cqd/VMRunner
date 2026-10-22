extension PGP {
    /// The vendor keys the app trusts to sign installers, one constant each. A key is pinned only after its fingerprint,
    /// recomputed from the constants here, matched the fingerprint the vendor publishes on its own https site, and after a real
    /// signature from it verified. Adding or replacing one is a code change with a test (ADR-0023).
    enum PinnedKeys {
        static let debianCD = PinnedKey(
            owner: "Debian CD signing key",
            fingerprint: "DF9B9C49EAA9298432589D76DA87E80D6294BE9B",
            created: 1_294_229_137,
            modulus: [
                "e8b458502c7628dca828184f91afdc15126b3e890308ad4898cb41faea21b3f0",
                "bf27c3b0f95f8c2ebe9c7d3851b6ae110ad70410616a4f786dba7980d7289b06",
                "a56875f866d01a9ef155bfa43d06191147f4b42c22e27044f207ee7cc68917db",
                "bea74a1a56ad14a21699e4eeff423f0d7d66bed6fef112afe9f8b78ed0e541eb",
                "c48b96be21ad409e1c0611884ef4ee6a1c8d903b086091898de11465155467e4",
                "5985ddeddf49d6f9df3894d78045db9ad47fd3c351d6c52afa8ab8e5d61e6b6f",
                "55712d09abcb6ef12178799bdd61fa7d31fe7fa41d72ca33dcd4cdb1adaa085b",
                "1f6599bae09bbf96b386d485ff304071736f93332f8e6d6b9f4f1ad7ab71499d",
                "320625a2e64c494d03c49fe8721038fd753674363087b4d7d738642689c1a115",
                "b426476edd2c86a189ec4a2118cd8a63cc32f0b791d5a38c3f4660bdbacb5961",
                "a8d1ba569cbdc44b92939efd0240949b231e3b4301c64191673d78d8879ea317",
                "f33e58077552601e8b48787c4426ff350ab68272254590233d9e597900000dec",
                "412a968cab154fdd82ca4766d05f5ba835ad647d6c17110ccc847cbd8167d301",
                "6ce6096c3f5234bcd1e39b8eb4d9fa6474db244caa8cb594f72f884d60778a87",
                "5104f27444a628d798ff3ec346b257fce87aa3178beeb2e4fbf7827ed0c35302",
                "34ec521ab35157338dc9aae455ae2ee1292b699b9a39da94abbebd88289a8b07",
            ].joined(),
            exponent: "010001")

        static let ubuntuCDImage = PinnedKey(
            owner: "Ubuntu CD Image Automatic Signing Key (2012)",
            fingerprint: "843938DF228D22F7B3742BC0D94AA3F0EFE21092",
            created: 1_336_774_248,
            modulus: [
                "bba4a2bbf2df3d0d6ee6bcca1282249c2df3cd17cfd3485dfcd22b3484544bdd",
                "d3a671711f36c5f6ea3b6ff1b76fbed904941d5f3f03a7b66a9202cacb3ae511",
                "550e864b11fb2035394057da4c8b2e76d2d1e584e50b766e39339bd475842b6e",
                "9f0d15ee2168e11435c91f728bbfead2aead3ec7b66d1fef821eae5725693b55",
                "487fc16706c5979fb3bfb51d38afca68635c23b042fa9b97367930079cf62e10",
                "217c64a97d4763baf2c4655d8e3f650293a7a14e4471262bd3c726ef140482b7",
                "432c06454310d804b0ee57a13a8ca11f01fc1920d4847b839c9bcdafb421792b",
                "41e2c21154d3d932db2a206ccb934e2d9ff226cdf126db8590c99433ddd99924",
                "a6c28d7c800b98e88f8471af5c69ad83a15dcd150e4868ab4a6f2d71a9294be7",
                "74fc81256c3e39dec92cc60eacddc4eced0f8fb9d69c73243406a6ad327ce67f",
                "10953a8b53eb99159e6cf63fee10d2045243f662f489f3f8eaf35b1b67ebf4dd",
                "c3e14c530bc171cc56d6bf3c93ab952f3db78d6ffc8cebb09d4a7824a999b5af",
                "d4d9464a4f23f2aef4d8869ff32b7df60449f189163865f423038230970d3497",
                "8a580432cb73a4c526d2db0eff39f540a2b176bc32d5985ab94cdd87c616cf64",
                "d567a630bf2eefd8360caf20dd53e40fde10e5a9eab9f1069bbe0afe478e9acb",
                "3c710a015fd54f14ca52d661424fed947463f452f32500372dd1a167030b5bf5",
            ].joined(),
            exponent: "010001")

        static let fedora44 = PinnedKey(
            owner: "Fedora 44 release key",
            fingerprint: "36F612DCF27F7D1A48A835E4DBFCF71C6D9F90A6",
            created: 1_736_879_931,
            modulus: [
                "b8515e488fda33ea1e9a6c428846889ecedb457e72e1c0e01f13db56b5f20531",
                "19a163dd6e2fcf0f29fd769f6c4705dde87396a107319e4c185a315f95240a69",
                "a10312388308e6af7ae83f464342e4253f84e5bc27c464492a9eea71c7af8762",
                "85394b76bc7b45b248433ae008ba9a0a7e8e45808f4f92f01506cad4a4eff6db",
                "28cdbf457f69e0d7c598515fc9bff05289efb55c66d0513dca7b338d5b0a65bd",
                "815f480e90fcd6101d4e362842bd58dca5341539b95b897599ff6665c28cb243",
                "a4d3c4f2cd0782d98441db411844ae37f570862783fb04588e97de846cfa64cb",
                "6a477b615502f5f8ef8a3740479c4cadcac59aec4639973aaa6344fcb963231f",
                "28460133d8f7cc10efa43164efd31fbb0e67d8daf95385a7feba9f84a2d42a47",
                "e97c2a30f7b9f3abc36aca7c12d3dc95a1b21f8c708a46d8f0ba7ea27defaced",
                "1e0bda702ead358f007ab32238d6e679e3685b684ae94869d54ac7e2a26ca6a3",
                "03a81101ce8aef13323131dfa9979300871ac2f5fa87677f9ddf3109fa203391",
                "53239a1b35251535a32fe6f420eaf715d5f6faa11828745d018bed5db2cab910",
                "c4291c524c9c8439355c2ecd28c22eddd7da6594a7499f22dd8af6806905cb75",
                "dae5e1a3b366d5b482e5414d62cbf0fab8fabd3a998a52bda727dc62610bbfb6",
                "bf34f932b800ac0451a873aea705fac4be4e7b916f456892bd9a34aa19fb7291",
            ].joined(),
            exponent: "010001")

        static let alpineCopa = PinnedKey(
            owner: "Natanael Copa (Alpine Linux release signer)",
            fingerprint: "0482D84022F52DF1C4E7CD43293ACD0907D9495A",
            created: 1_418_203_196,
            modulus: [
                "db89bf3c82fd5d0607847b3d53221e80e65033465d3626b76d6240e83ebe6540",
                "662fd2a28f956a5dde38067bc9fdd24ac6993f56da7a2845dc998d9e943db858",
                "489fadb9be95b8a72bb7044e5cfda034da890398f7be45d0e34ef6e4256283b2",
                "37602a738ec2914adc1e81901e941f19c82e336f5e49ed8bd356477aa9afeeba",
                "1f07db55f687fec8649cf9d02331cb3f2f91dc8fda7888199e1f3e2d1c56db20",
                "f25e2985b349e4fc0538b3189746f981e28cbe2c91331c50df788d6bd5fe45c5",
                "9e47be752107dac7ac4d71b3abc4d4737f39bbedf6382b305ecdc9ea2459eb97",
                "fa7caa006a1872a6aeb723bf6305edd0961c600f9b5fef74f3e352939c10e1f8",
                "b86bd7ecfe30daa43458b0530c33b8eff062b98f400c8c0417569f35788991ee",
                "1f9a30d830a03e1eb9e1a1cbc8e3c5485f90b9f82e5a24e2b037610ea5d5d2be",
                "6b32b134ad8087387df71a62e81f008127ed976071899395b22984798e98e82d",
                "f3d27ee8a7fd5fa995466ba623771959eb5fd851157d2f6fdb80b673c351c372",
                "c44a80d3d22896b021dcb22c4262aaaf8f32412744d210854265ea4e381a7c95",
                "f325e181190553333b1e79f0bcdb176791fd712caf7017ec66b58c3bb63795b3",
                "20e6b462f265d71710c5cd1166e99a32567cd5d57fbaef06dbe1d3ac93192bdd",
                "f7a2fde96f1699dfcfc26c203dd12064e71a95aad4cd007a4891d1a3f74bf697",
            ].joined(),
            exponent: "010001")

        /// The Fedora release keys that are pinned, by release number. A release without a key here fails closed.
        static func fedora(release: Int) -> [PinnedKey] {
            switch release {
            case 44: [fedora44]
            default: []
            }
        }

        /// Every pinned key, for tests that check each constant against its fingerprint.
        static let all = [debianCD, ubuntuCDImage, fedora44, alpineCopa, almaLinux10, rockyLinux10]

        /// Checked on 2026-10-22 against almalinux.org/security and the AlmaLinux 10 release notes: no expiry.
        static let almaLinux10 = PinnedKey(
            owner: "AlmaLinux OS 10",
            fingerprint: "EE6DB7B98F5BF5EDD9DA0DE5DEE5C11CC2A1E572",
            created: 1_720_707_311,
            modulus: [
                "af83c22503119ac95f333a2f44c7e3ddf25ae3d81ac1ce5a06f2b8bce0e469f6",
                "8f288eaee5ca42a62049477b5d5c403d8b7ff6b895c410e047376da883efce97",
                "e8ad9e5529411009d93337e30e0f11eb749fb01baef1893e954caa941ac39d20",
                "d868faee380ccb233dabf368a4202d630db8a966c3053c51cf238fe16b2c96c4",
                "9de81b145ed266ed60b07d12510a9e0b7efe17e8ec92e495a91bce7c8846e544",
                "17756b65bf755c2eabfe276a7c9a0dc815d22a2763cf4230a8e86090b524f38a",
                "f396d0e8dc0cf01aabac77b3c4ba13a6aa29ce869d2131d5ecced0f84d5ca1c3",
                "cda25eefcea2738039b6536587cce99f1bb660ea928a34693fa83cf0ae677c82",
                "fdc694f5d86f0925c44ff086a1773784be79bbd3d5aa67159bf9b0bee1089840",
                "2fc55734fdd07311493e1705bc2ac68ddc7a142ab0b8fcdaa099a433f3fe369e",
                "9eeeda3f8138e27884072434475677cac1f3a098374d2c7719ef2c1b29f15dc8",
                "c04a972e118ea01b1a832eb567c84a08cfac88e1a7c666dbc9b81a2ceb3e0cf9",
                "71b7d2ebb602c91ce0f0983f7aa32b143c9b80d25bfc28c892a48774b52a69f5",
                "69ffc070469118311987f342eed646f459a906a579fb752535d73a33733eeaf4",
                "4642726f7c85c00a31a5e3f2a3f5abba9338d4e1d6e7c704a9d0baae20a725c4",
                "b853ce112e3fa1c2fb9f05507b6ab790ef9b044e729eca8cd95be3f5e84d6dff",
            ].joined(),
            exponent: "010001")

        /// Checked on 2026-10-22 against rockylinux.org/keys and the key file on download.rockylinux.org: no expiry.
        static let rockyLinux10 = PinnedKey(
            owner: "Release Engineering (Rocky Linux 10)",
            fingerprint: "FC226859C0860BF0DDB95B085B106C736FEDFC85",
            created: 1_747_640_745,
            modulus: [
                "c56076fd397e7f865489b987b3c67cda6f4d4f52779ce3f5af45d5394110b24b",
                "395289cc5d09846b6ac404627cad181ad330cedf1920ce1fd06d56929f16f396",
                "f32c5f0578245db053da9dbf3caf7aaa3222b2d6c61992b9c94e6a8474cee07d",
                "f431a2af3bcbbeab721c76dc5cd48d8eb864eb590d3e30023b7593e6353aabbc",
                "196a92cfd50fa523f52498a55d27d7619d150648dfaf8c5ee235ef4bebd2a456",
                "694f1c974130de7a94f6b381be71cfcda6f95210b2839f9713b43046928ace24",
                "7158d738d215353a94fccabe21a19770f4b8a6740d3273b9a78b3edc5863df7c",
                "cadf050724d5329f2c2f16b13489df664f4ff1a295d4c8c843afdb6f687e17c1",
                "9d8f07f8c783d5c716df9db21df96f2abf4f7e1c6dda542e37ba821699b9922a",
                "75de180a4a704bf4cf094480af8de76b638437c8e7c5672b5622c62c6362801d",
                "ef252d369169f3ed9c2f135a48aa4773fe769696a299e86b2b950151482b68f3",
                "8b1f0f802f93c18487f8825c9b0d4ed56c290edf2a25f004f5287d5f4ee67db1",
                "a7a74b49186ffe1d7b92770208fc65d07911342f7e034fb5dc6377b7b6e6020a",
                "84a99efb6656f2a95b8d937c67e3c115a95bf7e26b7d181cb5d2a1f7f6e86dfc",
                "1392df4138e397de6ec905afdf0a4313152b0ce7b37768436778895564593f76",
                "19d738097b1c255683d36c351eff03dcac5a390e89f86050f9e1cb54a7f3b7f7",
            ].joined(),
            exponent: "010001")
    }
}
