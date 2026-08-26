source ../.env

forge script MemeverseScript.s.sol:MemeverseScript --rpc-url sepolia \
    --priority-gas-price 500000000 --with-gas-price 1500000000 \
    --optimize --optimizer-runs 200 \
    --via-ir \
    --broadcast --ffi -vvvv \
    --verify

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url bsc_testnet \
#     --with-gas-price 150000000 \
#     --optimize --optimizer-runs 200 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify \
#     --slow

# forge script MemeverseScript.s.sol:MemeverseScript --rpc-url base_sepolia \
#     --with-gas-price 1200000 \
#     --optimize --optimizer-runs 200 \
#     --via-ir \
#     --broadcast --ffi -vvvv \
#     --verify

