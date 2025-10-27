source ../.env

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url sepolia \
#     --priority-gas-price 500000000 --with-gas-price 1500000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url bsc_testnet \
#     --with-gas-price 200000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify \
#     --slow

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url base_sepolia \
#     --with-gas-price 1200000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url arbitrum_sepolia \
#     --with-gas-price 3000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url avalanche_fuji \
#     --priority-gas-price 1000000001 --with-gas-price 1000000001 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url polygon_amoy \
#     --priority-gas-price 40000000000 --with-gas-price 50000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url sonic_blaze \
#     --priority-gas-price 100000000 --with-gas-price 1100000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify
    
# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url blast_sepolia \
#     --priority-gas-price 300 --with-gas-price 1000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url scroll_sepolia \
#     --priority-gas-price 1000 --with-gas-price 600000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url monad_testnet \
#     --with-gas-price 52000000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify --verifier sourcify \
#     --verifier-url 'https://sourcify-api-monad.blockvision.org'

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url optimistic_sepolia \
#     --with-gas-price 1000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url linea_sepolia \
#     --with-gas-price 250000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url zksync_sepolia \
#     --with-gas-price 25000000 \
#     --optimize --optimizer-runs 100000 \
#     --via-ir \
#     --skip-simulation \
#     --broadcast --ffi -vvvv \
#     --verify

forge script MemeverseScript.s.sol:MemeverseScript --rpc-url flow_testnet \
    --with-gas-price 1000000 \
    --optimize --optimizer-runs 100000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify --verifier blockscout \
    --verifier-url 'https://evm-testnet.flowscan.io/api/' \
    --slow

## TestScript ##

# forge script TestScript.s.sol:TestScript --rpc-url monad_testnet \
#     --with-gas-price 52000000000 \
#     --via-ir \
#     --broadcast --ffi -vvvv

# forge script TestScript.s.sol:TestScript --rpc-url bsc_testnet \
#     --with-gas-price 1000000000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \

# forge script TestScript.s.sol:TestScript --rpc-url arbitrum_sepolia \
#     --with-gas-price 100000000 \
#     --via-ir \
#     --broadcast --ffi -vvvv

# forge script TestScript.s.sol:TestScript --rpc-url polygon_amoy \
#     --priority-gas-price 40000000000 --with-gas-price 50000000000 \
#     --via-ir \
#     --broadcast --ffi -vvvv

# forge script TestScript.s.sol:TestScript --rpc-url scroll_sepolia \
#     --priority-gas-price 1000 --with-gas-price 600000000 \
#     --via-ir \
#     --broadcast --ffi -vvvv

# forge script TestScript.s.sol:TestScript --rpc-url base_sepolia \
#     --with-gas-price 1200000 \
#     --via-ir \
#     --broadcast --ffi -vvvv
