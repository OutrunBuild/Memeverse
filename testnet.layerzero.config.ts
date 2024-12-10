import { EndpointId } from "@layerzerolabs/lz-definitions";
const bsc_testnet_MemeverseRegistrationCenter = {
    eid: EndpointId.BSC_V2_TESTNET,
    contractName: "MemeverseRegistrationCenter",
};

const base_sepolia_MemeverseRegistrar = {
    eid: EndpointId.BASESEP_V2_TESTNET,
    contractName: "MemeverseRegistrar",
};
const blast_sepolia_MemeverseRegistrar = {
    eid: EndpointId.BLAST_V2_TESTNET,
    contractName: "MemeverseRegistrarOnBlast",
};

export default {
    contracts: [
        { contract: bsc_testnet_MemeverseRegistrationCenter },
        { contract: base_sepolia_MemeverseRegistrar },
        { contract: blast_sepolia_MemeverseRegistrar },
    ],
    connections: [
        {
            from: bsc_testnet_MemeverseRegistrationCenter,
            to: base_sepolia_MemeverseRegistrar,
            config: {
                sendLibrary: '0x55f16c442907e86D764AFdc2a07C2de3BdAc8BB7',
                receiveLibraryConfig: { receiveLibrary: '0x188d4bbCeD671A7aA2b5055937F79510A32e9683', gracePeriod: 0 },
                sendConfig: {
                    executorConfig: { maxMessageSize: 10000, executor: '0x31894b190a8bAbd9A067Ce59fde0BfCFD2B18470' },
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ['0x0eE552262f7B562eFcED6DD4A7e2878AB897d405'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ['0x0eE552262f7B562eFcED6DD4A7e2878AB897d405'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: base_sepolia_MemeverseRegistrar,
            to: bsc_testnet_MemeverseRegistrationCenter,
            config: {
                sendLibrary: '0xC1868e054425D378095A003EcbA3823a5D0135C9',
                receiveLibraryConfig: { receiveLibrary: '0x12523de19dc41c91F7d2093E0CFbB76b17012C8d', gracePeriod: 0 },
                sendConfig: {
                    executorConfig: { maxMessageSize: 10000, executor: '0x8A3D588D9f6AC041476b094f97FF94ec30169d3D' },
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ['0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ['0xe1a12515F9AB2764b887bF60B923Ca494EBbB2d6'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: bsc_testnet_MemeverseRegistrationCenter,
            to: blast_sepolia_MemeverseRegistrar,
            config: {
                sendLibrary: '0x55f16c442907e86D764AFdc2a07C2de3BdAc8BB7',
                receiveLibraryConfig: { receiveLibrary: '0x188d4bbCeD671A7aA2b5055937F79510A32e9683', gracePeriod: 0 },
                sendConfig: {
                    executorConfig: { maxMessageSize: 10000, executor: '0x31894b190a8bAbd9A067Ce59fde0BfCFD2B18470' },
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ['0x0eE552262f7B562eFcED6DD4A7e2878AB897d405'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ['0x0eE552262f7B562eFcED6DD4A7e2878AB897d405'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
        {
            from: blast_sepolia_MemeverseRegistrar,
            to: bsc_testnet_MemeverseRegistrationCenter,
            config: {
                sendLibrary: '0x701f3927871EfcEa1235dB722f9E608aE120d243',
                receiveLibraryConfig: { receiveLibrary: '0x9dB9Ca3305B48F196D18082e91cB64663b13d014', gracePeriod: 0 },
                sendConfig: {
                    executorConfig: { maxMessageSize: 10000, executor: '0xE62d066e71fcA410eD48ad2f2A5A860443C04035' },
                    ulnConfig: {
                        confirmations: 1,
                        requiredDVNs: ['0x939Afd54A8547078dBEa02b683A7F1FDC929f853'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
                receiveConfig: {
                    ulnConfig: {
                        confirmations: 5,
                        requiredDVNs: ['0x939Afd54A8547078dBEa02b683A7F1FDC929f853'],
                        optionalDVNs: [],
                        optionalDVNThreshold: 0,
                    },
                },
            },
        },
    ],
};
