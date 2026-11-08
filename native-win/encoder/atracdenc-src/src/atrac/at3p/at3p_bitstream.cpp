/*
 * This file is part of AtracDEnc.
 *
 * AtracDEnc is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * AtracDEnc is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with AtracDEnc; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#include "at3p_bitstream_impl.h"
#include "at3p_bitstream.h"
#include "at3p_gha.h"
#include "at3p_tables.h"
#include <env.h>
#include <util.h>

#include "ff/atrac3plus_data.h"

#include <iostream>
#include <limits>
#include <memory>

namespace NAtracDEnc {

using namespace NAt3p;
using std::vector;
using std::make_pair;
using std::pair;

static THuffTables HuffTabs;

TTonePackResult CreateFreqBitPack(const TAt3PGhaData::TWaveParam* const param, int len)
{
    const int MaxBits = 10;

    int bits[2] = {MaxBits, MaxBits};

    std::vector<TTonePackResult::TEntry> res[2];
    res[0].reserve(len);
    res[1].reserve(len);

    // try ascending order
    {
        auto& t = res[0];
        uint16_t prevFreqIndex = param->FreqIndex & 1023;
        t.emplace_back(TTonePackResult::TEntry{prevFreqIndex, MaxBits});

        for (int i = 1; i < len; i++) {
            uint16_t curFreqIndex = param[i].FreqIndex & 1023;
            if (prevFreqIndex < 512) {
                t.emplace_back(TTonePackResult::TEntry{curFreqIndex, MaxBits});
                bits[0] += MaxBits;
            } else {
                uint16_t b = GetFirstSetBit(1023 - prevFreqIndex) + 1;
                uint16_t code = curFreqIndex - (1024 - (1 << b));
                t.emplace_back(TTonePackResult::TEntry{code, b});
                bits[0] += b;
            }
            prevFreqIndex = curFreqIndex;
        }
    }

    // try descending order
    if (len > 1) {
        auto& t = res[1];
        uint16_t prevFreqIndex = param[len - 1].FreqIndex & 1023;
        t.emplace_back(TTonePackResult::TEntry{prevFreqIndex, MaxBits});

        for (int i = len - 2; i >= 0; i--) {
            uint16_t curFreqIndex = param[i].FreqIndex & 1023;
            uint16_t b = GetFirstSetBit(prevFreqIndex) + 1;
            t.emplace_back(TTonePackResult::TEntry{curFreqIndex, b});
            bits[1] += b;
            prevFreqIndex = curFreqIndex;
        }

    }

    if (len == 1 || bits[0] < bits[1]) {
        return {res[0], bits[0], ETonePackOrder::ASC};
    } else {
        return {res[1], bits[1], ETonePackOrder::DESC};
    }
}

uint32_t TDumper::GetConsumption() const noexcept
{
    return std::accumulate(Buf.begin(), Buf.end(), 0,
        [](uint32_t acc, const std::pair<uint16_t, uint8_t>& x) noexcept -> uint32_t { return acc + x.second; });
}

IBitStreamPartEncoder::EStatus TConfigure::Encode(void* frameData, TBitAllocHandler&)
{
    TSpecFrame* frame = TSpecFrame::Cast(frameData);

    frame->WordLen.resize(frame->NumQuantUnits);

    if (frame->IsLowRate64k()) {
        // Stage E3: the 64 kbps allocation profile measured from the
        // reference encoder's own 64k streams (stage E0). Per-channel
        // static word-length tables = the measured median profile:
        // a 5-6 plateau over the low quant units, a step down through
        // the mids, and a flat wordlen-1 tail in ch0. Ch1 is coded
        // only through QU17; at QU18-26 (~8.3 kHz and up) its word
        // length is 0 and the code-table section carries the
        // spectrum-clone flag instead (see TQuantUnitsEncoder), so
        // the decoder duplicates ch0's spectrum -- the reference
        // encoder's 64k "stereo" is dual-mono in the top band.
        // Entries past QU26 are unreachable (WriteFrame caps this
        // rung at 27 quant units) and just extend the floors.
        static const uint8_t wlCh0[32] = {
            6, 6, 6, 5, 5, 5, 5, 5,
            4, 3, 2, 2, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1
        }; // sum over QU0-26: 69 (measured mean 72.3)
        static const uint8_t wlCh1[32] = {
            6, 6, 6, 5, 5, 5, 5, 5,
            3, 3, 2, 2, 1, 1, 1, 1,
            1, 1, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        }; // sum over QU0-26: 59 (measured mean 60.3)

        // Budget shed at this rung is a ladder (CheckFrameDone
        // raises ShedLevel between repeat passes):
        //   levels 0-5:  thin word lengths toward the floors --
        //     every coded word length drops by one per level, never
        //     below 1 for ch0 across the whole band and for ch1
        //     through QU17 (0 in ch1's cloned band). Only precision
        //     thins; the 27-QU frame and the full bandwidth survive.
        //     This is the reference profile's own variation axis:
        //     its word-length sums move +/-8 around a fixed shape.
        //   levels 6-11: extend ch1's spectrum clone downward, one
        //     quant unit per level (QU17 first, down to QU12): the
        //     unit's ch1 word length becomes 0 and the decoder
        //     duplicates ch0 there too. Sony holds the clone
        //     boundary at QU18 on real music, but atracdenc's
        //     peak-normalized scaler leaves wordlen-1 spectra much
        //     denser than Sony's (their quantizer zeroes most of
        //     the tail), so the densest frames need the extra
        //     headroom this buys (~50-60 bits per unit).
        //   levels 12+:  mute ch0's top quant units one per level
        //     (QU26 down; applied in TQuantUnitsEncoder, which
        //     encodes an all-zero unit there). Quant-unit count,
        //     and with it every section count in the frame, stays
        //     at 27 -- only the muted units' content goes.
        // Dropping quant units (the pre-E3 shed) is not used at
        // this rung at all.
        const int level = static_cast<int>(frame->ShedLevel);
        for (size_t i = 0; i < frame->WordLen.size(); i++) {
            const int floor1 = (i >= 18) ? 0 : 1;
            int v0 = static_cast<int>(wlCh0[i]) - level;
            int v1 = static_cast<int>(wlCh1[i]) - level;
            v1 = v1 < floor1 ? floor1 : v1;
            if (level >= 6 && static_cast<int>(i) >= 18 - (level - 5)) {
                v1 = 0; // clone extension: this unit is cloned too
            }
            frame->WordLen[i].first = static_cast<uint8_t>(v0 < 1 ? 1 : v0);
            frame->WordLen[i].second = static_cast<uint8_t>(v1);
        }
    } else {
        for (size_t i = 0; i < frame->WordLen.size(); i++) {
            static uint8_t allocTable[32] = {
                7, 7, 7, 7, 7, 7, 7, 7,
                7, 7, 7, 7, 7, 7, 7, 7,
                7, 6, 6, 6, 6, 6, 6, 6,
                6, 6, 5, 5, 4, 3, 2, 1
            };
            frame->WordLen[i].first = allocTable[i];
            frame->WordLen[i].second = allocTable[i];
        }
    }

    frame->SfIdx.resize(frame->NumQuantUnits);

    for (size_t i = 0; i < frame->SfIdx.size(); i++) {
        frame->SfIdx[i].first = frame->Chs[0].Sce.ScaledBlocks.at(i).ScaleFactorIndex;
        if (frame->Chs.size() > 1)
            frame->SfIdx[i].second = frame->Chs[1].Sce.ScaledBlocks.at(i).ScaleFactorIndex;
    }

    frame->SpecTabIdx.resize(frame->NumQuantUnits);

    Insert(frame->NumQuantUnits - 1, 5);
    Insert(0, 1); //mute flag

    frame->AllocatedBits = GetConsumption();

    return EStatus::Ok;
}

size_t FindBestWlDeltaEncode(const int8_t* delta, uint32_t sz, size_t tableStart, size_t tableEndl) noexcept {
    size_t best = 0;
    size_t consumed = std::numeric_limits<size_t>::max();
    static_assert(HuffTabs.WordLens.size() == 4, "unexpected wordlen huffman code table size");
    for (size_t i = tableStart; i <= tableEndl; i++) {
        const std::array<TVlcElement, 8>& wlTab = HuffTabs.WordLens[i];
        size_t t = 0;
        for (size_t j = 1; j < sz; j++) {
            t += wlTab[delta[j]].Len;
        }
        if (t < consumed) {
            consumed = t;
            best = i;
        }
    }

    return best;
}

void TWordLenEncoder::VlEncode(const std::array<TVlcElement, 8>& wlTab, size_t idx, size_t sz, const int8_t* data) noexcept {
    Insert(3, 2); // 0 - constant number of bits, 3 - VLC
    Insert(0, 2); // weight_idx
    Insert(0, 2); // chan->num_coded_vals = ctx->num_quant_units;

    Insert(idx, 2);
    Insert(data[0], 3);
    for (size_t i = 1; i < sz; i++) {
        Insert(wlTab[data[i]].Code,  wlTab[data[i]].Len);
    }
}

IBitStreamPartEncoder::EStatus TWordLenEncoder::Encode(void* frameData, TBitAllocHandler&) {
    auto specFrame = TSpecFrame::Cast(frameData);

    ASSERT(specFrame->WordLen.size() >= specFrame->NumQuantUnits);

    int8_t deltasCh0[32];
    //int8_t deltasCh1[32];
    int8_t interChDeltas[32];
    int8_t maxDeltaCh0 = 0;
    //int8_t maxDeltaCh1 = 0;
    int8_t maxInterChDelta;

    {
        int8_t t = specFrame->WordLen[0].second - specFrame->WordLen[0].first;
        maxInterChDelta = abs(t);
        interChDeltas[0] = t & 7;
    }

    deltasCh0[0] = specFrame->WordLen[0].first;
    //deltasCh1[0] = specFrame->WordLen[0].second;

    for (size_t i = 1; i < specFrame->NumQuantUnits; i++) {
        int8_t deltaCh0 = specFrame->WordLen[i].first - specFrame->WordLen[i-1].first;
        //int8_t deltaCh1 = specFrame->WordLen[i].second - specFrame->WordLen[i-1].second;
        int8_t t = specFrame->WordLen[i].second - specFrame->WordLen[i].first;
        //0 - 7, so only 3 bits
        maxDeltaCh0 |= abs(deltaCh0);
        //maxDeltaCh1 |= abs(deltaCh1);
        deltasCh0[i] = deltaCh0 & 7;
        //deltasCh1[i] = deltaCh1 & 7;

        maxInterChDelta |= abs(t);
        interChDeltas[i] = t & 7;
    }

    {
        size_t tableStart, tableEnd;
        if (maxDeltaCh0 >= 3) {
            tableStart = 2;
            tableEnd = 3;
        } else if (maxDeltaCh0 == 2) {
            tableStart = 1;
            tableEnd = 1;
        } else {
            tableStart = 0;
            tableEnd = 0;
        }

        const size_t idx = FindBestWlDeltaEncode(deltasCh0, specFrame->NumQuantUnits, tableStart, tableEnd);
        const std::array<TVlcElement, 8>& wlTab = HuffTabs.WordLens[idx];

        VlEncode(wlTab, idx, specFrame->NumQuantUnits, deltasCh0);
    }

    if (specFrame->Chs.size() == 2) {
        size_t tableStart, tableEnd;
        if (maxInterChDelta >= 3) {
            tableStart = 2;
            tableEnd = 3;
        } else if (maxInterChDelta == 2) {
            tableStart = 1;
            tableEnd = 1;
        } else {
            tableStart = 0;
            tableEnd = 0;
        }

        const size_t idx = FindBestWlDeltaEncode(interChDeltas, specFrame->NumQuantUnits, tableStart, tableEnd);
        const std::array<TVlcElement, 8>& wlTab = HuffTabs.WordLens[idx];

        Insert(1, 2); // 0 - constant number of bits
        Insert(0, 2); // chan->num_coded_vals = ctx->num_quant_units;

        Insert(idx, 2);
        for (size_t i = 0; i < specFrame->NumQuantUnits; i++) {
            Insert(wlTab[interChDeltas[i]].Code,  wlTab[interChDeltas[i]].Len);
        }
    }

    return EStatus::Ok;
}

IBitStreamPartEncoder::EStatus TSfIdxEncoder::Encode(void* frameData, TBitAllocHandler&) {
    auto specFrame = TSpecFrame::Cast(frameData);

    if (specFrame->SfIdx.empty()) {
        return EStatus::Ok;
    }

    for (size_t ch = 0; ch < specFrame->Chs.size(); ch++) {

        Insert(0, 2); // 0 - constant number of bits

        if (ch == 0) {
            for (size_t i = 0; i < specFrame->NumQuantUnits; i++) {
                Insert(specFrame->SfIdx[i].first, 6);
            }
        } else {
            for (size_t i = 0; i < specFrame->NumQuantUnits; i++) {
                Insert(specFrame->SfIdx[i].second, 6);
            }
        }
    }

    return EStatus::Ok;
}

void TQuantUnitsEncoder::EncodeCodeTab(bool useFullTable, size_t channels,
    size_t numQuantUnits, const std::vector<std::pair<uint8_t, uint8_t>>& specTabIdx,
    const std::vector<std::pair<uint8_t, uint8_t>>& wordLen,
    std::vector<std::pair<uint16_t, uint8_t>>& data)
{
    data.emplace_back(useFullTable, 1); // use full table

    for (size_t ch = 0; ch < channels; ch++) {

        data.emplace_back(0, 1); // table type

        data.emplace_back(0, 2); // 0 - constant number of bits

        data.emplace_back(0, 1); // num_coded_vals equal to used_quant_units

        for (size_t i = 0; i < numQuantUnits; i++) {
            const uint8_t wl = (ch == 0) ? wordLen[i].first : wordLen[i].second;
            if (wl != 0) {
                data.emplace_back((ch == 0) ? specTabIdx[i].first : specTabIdx[i].second,
                                  useFullTable + 2);
            } else if (ch != 0 && wordLen[i].first != 0) {
                // No spectrum is coded for this unit in this channel.
                // The format gives such a unit a one-bit field here
                // instead of a table index: 0 is the clone flag --
                // the decoder copies the master channel's spectrum
                // for the unit. (Stage E3 uses this for ch1 QU18-26
                // at 64 kbps, mirroring the reference encoder.)
                data.emplace_back(0, 1); // clone spectrum from ch0
            }
            // A zero word length in the master channel itself needs
            // no field at all: the decoder reads nothing for it.
        }
    }
}

void TQuantUnitsEncoder::EncodeQuSpectra(const int* qspec, const size_t num_spec, const size_t idx,
    std::vector<std::pair<uint16_t, uint8_t>>& data) {
    const Atrac3pSpecCodeTab *tab = &atrac3p_spectra_tabs[idx];
    const std::array<TVlcElement, 256>& vlcTab = HuffTabs.VlcSpecs[idx];

    size_t groupSize = tab->group_size;
    size_t numCoeffs = tab->num_coeffs;
    size_t bitsCoeff = tab->bits;
    bool isSigned  = tab->is_signed;

    for (size_t pos = 0; pos < num_spec;) {
        if (groupSize != 1) {
            // TODO: Acording to FFmpeg it should be possible
            // to skip group, if all rest of coeffs is zero
            // but this should be checked with real AT3P decoder
            data.emplace_back(1, 1);
        }

        for (size_t j = 0; j < groupSize; j++) {
            uint32_t val = 0;
            int8_t signs[4] = {0};
            for (size_t i = 0; i < numCoeffs; i++) {
                int16_t t = qspec[pos++];
#ifndef NDEBUG
                {
                    uint16_t x = std::abs(t);
                    x >>= (uint16_t)(bitsCoeff - (int)isSigned);
                    ASSERT(x == 0);
                }
#endif
                if (!isSigned && t != 0) {
                    signs[i] = t > 0 ? 1 : -1;
                    if (t < 0)
                        t = -t;
                } else {
                    t = t & ((1u << (bitsCoeff)) - 1);
                }
                t <<= (bitsCoeff * i);
                val |= t;
            }

            ASSERT(val <= 255);

            const TVlcElement& el = vlcTab.at(val);

            data.emplace_back(el.Code, el.Len);
            for (size_t i = 0; i < 4; i++) {
                if (signs[i] != 0) {
                    if (signs[i] > 0) {
                        data.emplace_back(0, 1);
                    } else {
                        data.emplace_back(1, 1);
                    }
                }
            }
        }
    }
}

size_t TQuantUnitsEncoder::TUnit::MakeKey(size_t ch, size_t qu, size_t worlen) {
    ASSERT(qu < 32);
    ASSERT(worlen < 8);
    return (ch << 8) | (qu << 3) | worlen;
}

TQuantUnitsEncoder::TUnit::TUnit(size_t qu, size_t wordlen)
    : Wordlen(wordlen)
    , Multiplier(1.0f / atrac3p_mant_tab[wordlen])
{
    Mantisas.resize(TScaleTable::SpecsPerBlock[qu]);
}

size_t TQuantUnitsEncoder::TUnit::GetOrCompute(const float* val, std::vector<std::pair<uint16_t, uint8_t>>& res)
{
    QuantMantisas(val, 0, Mantisas.size(), Multiplier, false, Mantisas.data());

    std::vector<std::pair<uint16_t, uint8_t>> tmp;

    size_t bestTab = 0;
    size_t consumed = std::numeric_limits<size_t>::max();

    for (size_t i = 0, tabIndex = Wordlen - 1; i < 8; i++, tabIndex += 7) {

        // A code table can only carry this unit if every mantissa
        // fits its coefficient field. EncodeQuSpectra packs unsigned
        // tables' magnitudes unmasked, so an oversized mantissa
        // overlaps the neighbouring coefficient's field; the
        // decoder then reads back different values, and where a
        // coefficient flips between zero and nonzero the sign-bit
        // count changes -- the rest of the frame desyncs. (Stage E3
        // hit this at 64 kbps word lengths: a transient spike of
        // magnitude 2 overflows the wordlen-1 unsigned table, whose
        // coefficients are a single bit.) Signed tables truncate
        // oversized values in place, which costs precision but
        // consumes identical bits on both sides, so only unsigned
        // tables are filtered. At the stock 352.8k word lengths the
        // mantissas always fit, so this changes nothing there.
        const Atrac3pSpecCodeTab& specTab = atrac3p_spectra_tabs[tabIndex];
        if (!specTab.is_signed) {
            const int limit = 1 << specTab.bits;
            bool fits = true;
            for (int m : Mantisas) {
                if (m >= limit || m <= -limit) {
                    fits = false;
                    break;
                }
            }
            if (!fits) {
                continue;
            }
        }

        EncodeQuSpectra(Mantisas.data(), Mantisas.size(), tabIndex, tmp);

        size_t t = std::accumulate(tmp.begin(), tmp.end(), 0,
            [](size_t acc, const std::pair<uint8_t, uint16_t>& x) noexcept -> size_t
                { return acc + x.second; });

        if (t < consumed) {
            consumed = t;
            ConsumedBits = t;
            bestTab = i;
            res.clear();
            res.swap(tmp);
            tmp.clear();
        } else {
            tmp.clear();
        }
    }
    if (consumed == std::numeric_limits<size_t>::max()) {
        // Every candidate was filtered out above. Cannot happen
        // with the vendored tables (each word length has signed
        // candidates, which are never filtered), but never emit a
        // unit with no spectrum: fall back to the unfiltered
        // cheapest-table choice.
        for (size_t i = 0, tabIndex = Wordlen - 1; i < 8; i++, tabIndex += 7) {
            EncodeQuSpectra(Mantisas.data(), Mantisas.size(), tabIndex, tmp);

            size_t t = std::accumulate(tmp.begin(), tmp.end(), 0,
                [](size_t acc, const std::pair<uint8_t, uint16_t>& x) noexcept -> size_t
                    { return acc + x.second; });

            if (t < consumed) {
                consumed = t;
                ConsumedBits = t;
                bestTab = i;
                res.clear();
                res.swap(tmp);
                tmp.clear();
            } else {
                tmp.clear();
            }
        }
    }
    return bestTab;
}

IBitStreamPartEncoder::EStatus TQuantUnitsEncoder::Encode(void* frameData, TBitAllocHandler&)
{
    auto specFrame = TSpecFrame::Cast(frameData);
    std::vector<
            std::vector<std::pair<uint16_t, uint8_t>>> data;
    for (size_t ch = 0; ch < specFrame->Chs.size(); ch++) {
        auto& chData = specFrame->Chs.at(ch);
        auto scaledBlocks = chData.Sce.ScaledBlocks;

        for (size_t qu = 0; qu < specFrame->NumQuantUnits; qu++) {
            size_t len = (ch == 0) ?
                specFrame->WordLen.at(qu).first :
                specFrame->WordLen.at(qu).second;

            data.push_back(std::vector<std::pair<uint16_t, uint8_t>>());

            if (len == 0) {
                // No spectrum coded for this unit in this channel:
                // TUnit/GetOrCompute cannot represent word length 0
                // (its code-table walk starts at Wordlen - 1), and
                // the bitstream carries none either -- for ch > 0
                // EncodeCodeTab writes the clone flag for the unit
                // instead, and SpecTabIdx keeps the flag value 0.
                if (ch == 0) {
                    specFrame->SpecTabIdx[qu].first = 0;
                } else {
                    specFrame->SpecTabIdx[qu].second = 0;
                }
                continue;
            }

            size_t key = TUnit::MakeKey(ch, qu, len);

            TUnit* unit;
            //  try_emplace
            auto it = UnitBuffers.find(key);
            if (it == UnitBuffers.end()) {
                unit = &(UnitBuffers.emplace(key, TUnit(qu, len)).first->second);
            } else {
                unit = &it->second;
            }

            const float* values = scaledBlocks.at(qu).Values.data();

            // Deepest rung of the low-rate shed ladder (stage E3):
            // from ShedLevel 12 up, ch0's top quant units are muted
            // one per level, QU26 first. The unit keeps its word
            // length, scale factor and code-table entry -- only the
            // spectrum is encoded as all zeros -- so the frame's
            // section counts stay at the full 27 quant units.
            if (ch == 0 && specFrame->IsLowRate64k() && specFrame->ShedLevel >= 12 &&
                static_cast<int>(qu) >= 26 - (static_cast<int>(specFrame->ShedLevel) - 12)) {
                static const std::vector<float> zeros(128, 0.0f);
                values = zeros.data();
            }

            auto tabIdx = unit->GetOrCompute(values, data.back());

            if (ch == 0) {
                specFrame->SpecTabIdx[qu].first = tabIdx;
            } else {
                specFrame->SpecTabIdx[qu].second = tabIdx;
            }
        }
        if (true /*frame.NumUsedQuantUnits > 2*/) {
            size_t numPwrSpec = atrac3p_subband_to_num_powgrps[atrac3p_qu_to_subband[specFrame->NumQuantUnits - 1]];
            data.push_back(std::vector<std::pair<uint16_t, uint8_t>>());
            auto& t = data.back();
            for (size_t i = 0; i < numPwrSpec; i++) {
                t.emplace_back(15, 4);
            }
        }
    }

    {
        std::vector<std::pair<uint16_t, uint8_t>> tabIdxData;
        EncodeCodeTab(true, specFrame->Chs.size(), specFrame->NumQuantUnits, specFrame->SpecTabIdx, specFrame->WordLen, tabIdxData);
        for (size_t i = 0; i < tabIdxData.size(); i++) {
            Insert(tabIdxData[i].first, tabIdxData[i].second);
        }
    }

    for (const auto& x : data) {
        for (size_t i = 0; i < x.size(); i++) {
            Insert(x[i].first, x[i].second);
        }
    }

    return EStatus::Ok;
}

static std::vector<IBitStreamPartEncoder::TPtr> CreateEncParts()
{
    vector<IBitStreamPartEncoder::TPtr> parts;
    parts.emplace_back(new TConfigure());
    parts.emplace_back(new TWordLenEncoder());
    parts.emplace_back(new TSfIdxEncoder());
    parts.emplace_back(new TQuantUnitsEncoder());
    parts.emplace_back(new TTonalComponentEncoder());

    return parts;
}

TAt3PBitStream::TAt3PBitStream(ICompressedOutput* container, uint16_t frameSz)
    : Container(container)
    , Encoder(CreateEncParts())
    , FrameSzToAllocBits((uint32_t)frameSz * 8 - 3) //Size of frame in bits for allocation. 3 bits is start bit and channel configuration
    , FrameSz(frameSz)
{
    NEnv::SetRoundFloat();
}

void TTonalComponentEncoder::WriteSubbandFlags(const bool* flags, size_t numFlags)
{

    size_t sum = 0;
    for (size_t i = 0; i < numFlags; i++) {
        sum += (uint32_t)flags[i];
    }

    if (sum == 0) {
        Insert(0, 1);
    } else if (sum == numFlags) {
        Insert(1, 1);
        Insert(0, 1);
    } else {
        Insert(1, 1);
        Insert(1, 1);
        for (size_t i = 0; i < numFlags; i++) {
           Insert(flags[i], 1);
        }
    }
}

void TTonalComponentEncoder::WriteTonalBlock(size_t channels, const TAt3PGhaData* tonalBlock)
{
    //GHA amplidude mode 1
    Insert(1, 1);

    //Num tone bands
    const TVlcElement& tbHuff = HuffTabs.NumToneBands[tonalBlock->NumToneBands - 1];
    Insert(tbHuff.Code, tbHuff.Len);

    if (channels == 2) {
        WriteSubbandFlags(tonalBlock->ToneSharing, tonalBlock->NumToneBands);
        WriteSubbandFlags(&tonalBlock->SecondIsLeader, 1);
        Insert(0, 1);
    }

    for (size_t ch = 0; ch < channels; ch++) {
        if (ch) {
            // each channel has own envelope
            Insert(0, 1);
        }
        // Envelope data
        for (int i = 0; i < tonalBlock->NumToneBands; i++) {
            if (ch && tonalBlock->ToneSharing[i]) {
                continue;
            }

            const auto envelope = tonalBlock->GetEnvelope(ch, i);

            if (envelope.first != TAt3PGhaData::EMPTY_POINT) {
                // start point present
                Insert(1, 1);
                Insert(envelope.first, 5);
            } else {
                Insert(0, 1);
            }

            if (envelope.second != TAt3PGhaData::EMPTY_POINT) {
                // stop point present
                Insert(1, 1);
                Insert(envelope.second, 5);
            } else {
                Insert(0, 1);
            }
        }

        // Num waves
        int mode = 0; //TODO: Calc mode
        Insert(mode, ch + 1);
        for (int i = 0; i < tonalBlock->NumToneBands; i++) {
            if (ch && tonalBlock->ToneSharing[i]) {
                continue;
            }
            Insert(tonalBlock->GetNumWaves(ch, i), 4);
        }
        // Tones freq
        if (ch) {
            // 0 - independed
            // 1 - delta to leader
            Insert(0, 1);
        }

        for (int i = 0; i < tonalBlock->NumToneBands; i++) {
            if (ch && tonalBlock->ToneSharing[i]) {
                continue;
            }

            auto numWaves = tonalBlock->GetNumWaves(ch, i);
            if (numWaves == 0) {
                continue;
            }

            const auto w = tonalBlock->GetWaves(ch, i);
            const auto pkt = CreateFreqBitPack(w.first, w.second);

            if (numWaves > 1) {
                Insert(static_cast<bool>(pkt.Order), 1);
            }

            for (const auto& d : pkt.Data) {
                Insert(d.Code, d.Bits);
            }
        }

        // Amplitude
        mode = 0; //TODO: Calc mode
        Insert(mode, ch + 1);

        for (int i = 0; i < tonalBlock->NumToneBands; i++) {
            if (ch && tonalBlock->ToneSharing[i]) {
                continue;
            }

            auto numWaves = tonalBlock->GetNumWaves(ch, i);
            if (numWaves == 0) {
                continue;
            }

            const auto w = tonalBlock->GetWaves(ch, i);
            for (size_t j = 0; j < numWaves; j++) {
                Insert(w.first[j].AmpSf, 6);
            }
        }

        // Phase
        for (int i = 0; i < tonalBlock->NumToneBands; i++) {
            if (ch && tonalBlock->ToneSharing[i]) {
                continue;
            }

            auto numWaves = tonalBlock->GetNumWaves(ch, i);
            if (numWaves == 0) {
                continue;
            }

            const auto w = tonalBlock->GetWaves(ch, i);
            for (size_t j = 0; j < w.second; j++) {
                Insert(w.first[j].PhaseIndex, 5);
            }
        }
    }
}

IBitStreamPartEncoder::EStatus TTonalComponentEncoder::CheckFrameDone(TSpecFrame* frame, TBitAllocHandler& ba) noexcept
{
    uint32_t totalConsumption = BitsUsed + ba.GetCurGlobalConsumption();

    if (totalConsumption > frame->SizeBits) {
        if (frame->IsLowRate64k()) {
            // Stage E3 shed ladder (applied by TConfigure and
            // TQuantUnitsEncoder, one step per ShedLevel): word
            // length thinning (levels 0-5), ch1 clone extension
            // (6-11), ch0 top-unit muting (12-20). Quant units are
            // never dropped at this rung -- dropping whole units is
            // what capped the naive E1/E2 encode at ~3.4 kHz, and
            // the ladder's last step still leaves every section
            // count at the full 27. Past the top of the ladder,
            // accept the frame as with the one-QU floor below; the
            // ladder buys ~850 bits beyond the floor profile, far
            // past any observed overage, so acceptance is a
            // termination guarantee, not an expected outcome.
            static const uint32_t MaxShedLevel = 20;
            if (frame->ShedLevel < MaxShedLevel) {
                frame->ShedLevel++;
                return EStatus::Repeat;
            }
            return EStatus::Ok;
        }
        if (frame->NumQuantUnits > 1) {
            if (frame->NumQuantUnits == 32) {
                frame->NumQuantUnits = 28;
            } else {
                frame->NumQuantUnits--;
            }
            return EStatus::Repeat;
        }
        // One quant unit is the floor: the frame cannot shrink any
        // further. Accept it instead of shedding to 0 (which would
        // corrupt the frame header written by TConfigure) or
        // repeating forever. A one-QU frame is a few hundred bits at
        // most, so this is unreachable in practice at any legal
        // frame size; it exists so small budgets (376 bytes) can
        // never wedge the shed loop.
    }
    return EStatus::Ok;
}

void TTonalComponentEncoder::DropTonalBlock(TSpecFrame* frame)
{
    // The tonal segment in Buf is [TonalFlagPos, AfterTonalPos): the
    // presence flag followed by the tonal block bits. The noise flag
    // and terminator inserted after it stay untouched. Replace the
    // segment with a single "no tonal component" flag.
    Buf.erase(Buf.begin() + TonalFlagPos, Buf.begin() + AfterTonalPos);
    Buf.insert(Buf.begin() + TonalFlagPos, std::make_pair((uint16_t)0, (uint8_t)1));
    frame->TonalBlock = nullptr;
    BitsUsed = GetConsumption();
}

IBitStreamPartEncoder::EStatus TTonalComponentEncoder::Encode(void* frameData, TBitAllocHandler& ba)
{
    auto specFrame = TSpecFrame::Cast(frameData);
    auto tonalBlock = specFrame->TonalBlock;

    // Check tonal component already encoded
    if (BitsUsed != 0) {
        if (tonalBlock && tonalBlock->NumToneBands > specFrame->NumQuantUnits) {
            // A budget shed (CheckFrameDone) shrank the frame below
            // the number of tone bands whose bits are already
            // buffered for it, so the tonal block no longer fits the
            // frame it belongs to. Drop the tonal block and encode
            // the frame from its spectrum alone. (This used to print
            // "TODO" and call abort(); at a 376-byte budget the shed
            // can legitimately reach this state on tonal content.)
            DropTonalBlock(specFrame);
        }
        return CheckFrameDone(specFrame, ba);
    }

    const size_t chNum = specFrame->Chs.size();

    if (chNum == 2) {
        Insert(0, 2); //swap_channels and negate_coeffs
    }

    for (size_t ch = 0; ch < chNum; ch++) {
        TAt3pMDCTWin winType = specFrame->Chs[ch].Sce.SubbandInfo.Win;
        uint8_t sbNum = atrac3p_qu_to_subband[specFrame->NumQuantUnits - 1] + 1;
        if (winType.IsAllSine()) {
            Insert(0, 1);
        } else if (winType.IsAllSteep(sbNum)) {
            Insert(1, 1);
            Insert(0, 1);
        } else {
            Insert(1, 1);
            Insert(1, 1);
            for (size_t i = 0; i < sbNum; i++) {
                Insert(winType.IsSbSteep(i), 1);
            }
        }
    }

    for (size_t ch = 0; ch < chNum; ch++) {
        Insert(0, 1); //gain comp
    }

    if (tonalBlock && tonalBlock->NumToneBands) {
        TonalFlagPos = Buf.size();
        Insert(1, 1);
        WriteTonalBlock(chNum, tonalBlock);
        AfterTonalPos = Buf.size();
    } else {
        Insert(0, 1);
    }

    Insert(0, 1); // no noise info
    // Terminator
    Insert(3, 2);

    BitsUsed = GetConsumption();

    return CheckFrameDone(specFrame, ba);
}

void TAt3PBitStream::WriteFrame(int channels, const TAt3PGhaData* tonalBlock, const std::vector<TSingleChannelElement>& sces)
{
    NBitStream::TBitStream bitStream;
    // First bit must be zero
    bitStream.Write(0, 1);
    // Channel block type
    // 0 - MONO block
    // 1 - STEREO block
    // 2 - Nobody know
    bitStream.Write(channels - 1, 2);

    // At the 64 kbps rung the frame starts at the reference
    // encoder's fixed 27 quant units (stage E0/E3); every other
    // frame size keeps the full 32.
    const uint32_t initialNumQuantUnits = (FrameSz <= 376) ? 27 : 32;

    TSpecFrame frame(FrameSzToAllocBits, initialNumQuantUnits, channels, tonalBlock, sces, FrameSz);

    Encoder.Do(&frame, bitStream);

    std::vector<char> buf = bitStream.GetBytes();

    ASSERT(bitStream.GetSizeInBits() <= FrameSz * 8);

    buf.resize(FrameSz);
    Container->WriteFrame(buf);
}

}
