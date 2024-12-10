source ../.env
# forge clean && forge build
forge script MemeverseScript.s.sol:MemeverseScript --rpc-url bsc_testnet \
    --with-gas-price 3000000000 \
    --optimize --optimizer-runs 10000 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify 

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url blast_sepolia \
#     --priority-gas-price 300 --with-gas-price 1200000 \
#     --optimize --optimizer-runs 10000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url base_sepolia \
#     --with-gas-price 1200000 \
#     --optimize --optimizer-runs 10000 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify 