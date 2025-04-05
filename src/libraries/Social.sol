//SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

library Social {
    enum Provider {
        X,
        Discord,
        Telegram,
        Others
    }

    struct Community {
        Provider provider;
        string handle;
    }
}
