// 0001000E.STK — the EKB record, byte-identical on every genuine
// disc. Canonical bytes from the Python package (stk_data.py).
export const STK_FILENAME = "0001000E.STK";
export const STK_BYTES = Uint8Array.from(
  (
    "454b42200000000000000000000000000000000000000000" +
    "00000000000000000001000e000000000000000000000000" +
    "000000000000000088f5b6dd2a9e15700000000c00000020" +
    "00000034c9249204fe000000000000004ad481adfefbe4f6" +
    "746e9ebfe23b6f4a7c70548686359ae42fd9b93c569b4d48" +
    "000000050100000001000028b760c006869404873b02a2d9" +
    "65d3e539bacfba145a134acfd7961bbd100a5f833383f969" +
    "d1d04a68"
  ).match(/../g).map((h) => parseInt(h, 16))
);
