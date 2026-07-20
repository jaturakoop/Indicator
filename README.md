# VWAP Indicator for MetaTrader 5

Volume Weighted Average Price (VWAP) แบบเขียนเองสำหรับ MT5 พร้อมแถบ
Standard Deviation ออกแบบมาให้ใช้ได้ทั้งการเทรดมือ และเป็นสัญญาณให้ EA (ผ่าน `iCustom`)

## ทำไมต้องเขียนเอง

MT5 มาตรฐาน **ไม่มี** VWAP ติดมาให้ ตัวฟรีทั่วไปมักมีข้อจำกัด เช่น
ไม่รีเซ็ตตามเซสชัน หรือคำนวณ SD ไม่ถูกต้อง ตัวนี้แก้จุดเหล่านั้น:

- รีเซ็ตได้ตาม **เซสชัน / สัปดาห์ / เดือน / ต่อเนื่อง**
- เลือกแหล่งราคาได้ (Typical, Close, HLC, OHLC)
- เลือกใช้ **Tick volume** หรือ **Real volume**
- แถบ SD คำนวณแบบ **volume-weighted variance** (ถูกต้องตามหลัก)

## การติดตั้ง

1. เปิด MetaEditor (กด F4 ใน MT5)
2. คัดลอกไฟล์ `VWAP.mq5` ไปที่โฟลเดอร์
   `MQL5/Indicators/` (เมนู File > Open Data Folder ใน MT5)
3. กด **Compile** (F7) ให้ได้ไฟล์ `VWAP.ex5`
4. ลากจากหน้าต่าง Navigator > Indicators ลงบนกราฟ

## พารามิเตอร์ (Inputs)

| พารามิเตอร์ | ค่าเริ่มต้น | ความหมาย |
|---|---|---|
| `InpAnchor` | Session | จุดรีเซ็ต VWAP (Session/Week/Month/Continuous) |
| `InpPriceType` | Typical | แหล่งราคา `(H+L+C)/3` |
| `InpVolumeType` | Tick | ใช้ tick volume หรือ real volume |
| `InpShowBands` | true | แสดงแถบ SD หรือไม่ |
| `InpBand1Mult` | 1.0 | ตัวคูณ SD แถบที่ 1 |
| `InpBand2Mult` | 2.0 | ตัวคูณ SD แถบที่ 2 |

> **หมายเหตุ:** Forex ส่วนใหญ่ไม่มี real volume จากตลาดกลาง จึงควรใช้
> **Tick volume** สำหรับ Forex ส่วนหุ้น/ฟิวเจอร์สที่โบรกส่ง real volume มา
> ให้เลือก Real volume ได้

## ไอเดียกลยุทธ์ที่ใช้ VWAP

1. **Mean reversion:** ราคาแตะ `-2SD` แล้วเด้ง = มองหา Buy กลับเข้า VWAP
   / ราคาแตะ `+2SD` = มองหา Sell
2. **Trend / bias filter:** ราคาปิดเหนือ VWAP = ฝั่ง Buy เท่านั้น,
   ปิดใต้ VWAP = ฝั่ง Sell เท่านั้น
3. **VWAP reclaim:** ราคาทะลุกลับข้าม VWAP หลังจากหลุดออกไป = สัญญาณกลับตัว

## เรียกใช้ใน EA (iCustom)

Buffer index ของ indicator:

| Index | Buffer |
|---|---|
| 0 | VWAP |
| 1 | +1SD |
| 2 | -1SD |
| 3 | +2SD |
| 4 | -2SD |

ตัวอย่างโค้ดใน EA:

```mq5
int vwap_handle;

int OnInit()
  {
   // พารามิเตอร์ต้องเรียงตามลำดับ input ใน VWAP.mq5
   vwap_handle = iCustom(_Symbol, _Period, "VWAP",
                         0,      // InpAnchor = ANCHOR_SESSION
                         0,      // InpPriceType = VWAP_PRICE_TYPICAL
                         0,      // InpVolumeType = VWAP_VOL_TICK
                         true,   // InpShowBands
                         1.0,    // InpBand1Mult
                         2.0);   // InpBand2Mult
   if(vwap_handle == INVALID_HANDLE)
      return(INIT_FAILED);
   return(INIT_SUCCEEDED);
  }

void OnTick()
  {
   double vwap[], lower2[];
   if(CopyBuffer(vwap_handle, 0, 0, 2, vwap)   < 2) return;  // VWAP line
   if(CopyBuffer(vwap_handle, 4, 0, 2, lower2) < 2) return;  // -2SD band

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ตัวอย่าง: ราคาต่ำกว่า -2SD = โซนซื้อ (mean reversion)
   if(bid < lower2[0])
     {
      // ... ใส่เงื่อนไข/ส่งออเดอร์ Buy ที่นี่
     }
  }
```

`ExampleStrategy_VWAP.mq5` ในโฟลเดอร์นี้เป็น EA ตัวอย่างเต็มรูปแบบที่ใช้
กลยุทธ์ mean-reversion ตาม VWAP bands (ไว้เป็นโครงให้ต่อยอด)

## VWAP + EMA Signal (ลูกศร No-Repaint)

`VWAP_EMA_Signal.mq5` เป็น indicator สัญญาณลูกศรตามกลยุทธ์:

**ตรรกะ**

1. **เทรนด์ + ความแรงของเทรนด์** — ระยะห่าง EMA(9) กับ VWAP
   - EMA9 อยู่ **เหนือ** VWAP = ขาขึ้น / **ใต้** = ขาลง
   - นำ**ขนาดของระยะห่าง** `EMA9 − VWAP` มาใช้ด้วย: ต้องห่างอย่างน้อย
     `InpMinVwapGapPoints` (ตั้ง 0 = ใช้แค่ทิศทางเหมือนเดิม)
   - เปิด `InpVwapExpanding` = ต้องกำลังถ่างออกเพิ่ม (เทรนด์กำลังเร่ง)
2. **Momentum** — ระยะห่าง EMA(5) − EMA(20)
   - ยิ่งถ่างออกในทิศทางเทรนด์ = แรงยิ่งมาก
   - ต้องห่างกันอย่างน้อย `InpMinSpreadPoints` (points) จึงยืนยัน
   - เปิด `InpRequireExpanding` = ต้องกำลัง**ถ่างออก**เพิ่มขึ้นด้วย
3. **Volatility gate** — เส้นบน/ล่างของ Bollinger Band ต้องกำลัง**ถ่างหนีห่างกัน**
   - ดูแค่ **ระยะห่างดิบ (บน − ล่าง)** เท่านั้น — **เส้นกลางไม่เกี่ยว**
   - `InpBBExpanding` (**เปิดเป็นค่าเริ่มต้น**) = width ตอนนี้ต้อง > width เมื่อ
     `InpBBExpandLookback` แท่งก่อน → แบนด์กำลังกางออก = ผันผวน/volume กำลังเข้า
   - `InpMinBBWidthPct` = ตัวกรองเสริม (ถ้าอยากบังคับความกว้างขั้นต่ำด้วย, 0 = ปิด)
4. **สัญญาณ** — ยิงลูกศรเมื่อ **เทรนด์ + momentum + volatility ครบ** (edge trigger ยิงครั้งเดียวตอนเริ่ม align)
   - ลูกศรเขียวขึ้น = Buy, ลูกศรแดงลง = Sell

**No-Repaint:** สัญญาณคำนวณจาก**แท่งที่ปิดแล้วเท่านั้น** (ข้ามแท่งกำลังวิ่ง)
ค่าที่ใช้ (EMA/VWAP ของแท่งปิด) นิ่งแล้ว ลูกศรที่ขึ้นจึงไม่ย้ายและไม่หายไป

**พารามิเตอร์สำคัญ**

| พารามิเตอร์ | ค่าเริ่มต้น | ความหมาย |
|---|---|---|
| `InpEMAfast` / `InpEMAmid` / `InpEMAslow` | 5 / 9 / 20 | คาบ EMA |
| `InpMinSpreadPoints` | 50 | ระยะห่าง EMA5-EMA20 ขั้นต่ำ (points) |
| `InpRequireExpanding` | true | EMA5-EMA20 ต้องกำลังถ่างออกเพิ่ม |
| `InpMinVwapGapPoints` | 0 | ระยะห่าง EMA9-VWAP ขั้นต่ำ (0=ใช้แค่ทิศทาง) |
| `InpVwapExpanding` | false | EMA9-VWAP ต้องกำลังถ่างออกเพิ่ม |
| `InpBBPeriod` / `InpBBDev` | 20 / 2.0 | คาบ / ส่วนเบี่ยงเบน Bollinger Band |
| `InpBBExpanding` | **true** | เส้นบน/ล่างต้องกำลังถ่างหนีห่างกัน |
| `InpBBExpandLookback` | 1 | เทียบ width กับเมื่อ N แท่งก่อน |
| `InpMinBBWidthPct` | 0 | (เสริม) ความกว้างขั้นต่ำ % ของเส้นกลาง, 0=ปิด |
| `InpVwapAnchor` | 0 (Session) | จุดรีเซ็ต VWAP |
| `InpArrowOffsetPoints` | 100 | ระยะลูกศรห่างจากแท่ง (points) |
| `InpAlertPopup` / `InpAlertPush` | false | แจ้งเตือนป๊อปอัป / มือถือ |

> **ต้องมี `VWAP.ex5` คอมไพล์ไว้ก่อน** เพราะตัวนี้ดึงค่า VWAP ผ่าน `iCustom`
> วางทั้ง `VWAP.mq5` และ `VWAP_EMA_Signal.mq5` ใน `MQL5/Indicators/` แล้วคอมไพล์ทั้งคู่

**Buffer สำหรับต่อยอดใน EA**

| Index | Buffer |
|---|---|
| 0 | Buy arrow (มีค่า = มีสัญญาณ Buy ที่แท่งนั้น) |
| 1 | Sell arrow |

## เวอร์ชัน TradingView (Pine Script)

`VWAP_EMA_Signal.pine` คือกลยุทธ์เดียวกันในเวอร์ชัน **Pine Script v5**
สำหรับ TradingView — ตรรกะเหมือน MT5 ทุกอย่าง (EMA9 vs VWAP + EMA5/20 spread + ลูกศร No-Repaint)

**วิธีติดตั้ง**

1. เปิด TradingView → เมนูล่าง **Pine Editor**
2. ลบโค้ดตัวอย่าง แล้ววางเนื้อหาจาก `VWAP_EMA_Signal.pine`
3. กด **Save** → **Add to chart**
4. ตั้ง Alert ได้จากเงื่อนไข "VWAP+EMA Buy" / "VWAP+EMA Sell"

**No-Repaint ใน Pine ทำยังไง**

- สัญญาณคำนวณจาก**แท่งที่ปิดแล้ว** (`buyRaw[1]`) แล้ววาดด้วย `offset = -1`
- ลูกศรจึงปรากฏบนแท่งที่ทริกเกอร์จริง และ**ไม่ขยับ/ไม่หาย**เมื่อแท่งปัจจุบันวิ่ง
- Background เทรนด์ก็อิงแท่งปิด (`[1]`) เช่นกัน

**ต่างจาก MT5 เล็กน้อย**

| หัวข้อ | MT5 | TradingView |
|---|---|---|
| ระยะ spread | points (`InpMinSpreadPoints`) | ticks (`minSpreadTicks`) |
| VWAP anchor | Session/Week/Month/Continuous | Session/Week/Month |
| VWAP volume | tick / real เลือกได้ | ใช้ volume ของ TradingView |

> TradingView ใช้ built-in `ta.vwap` ซึ่งอิง volume ของแพลตฟอร์มเอง
> ผลลัพธ์อาจต่างจาก MT5 (ที่ใช้ tick volume ของโบรก) เล็กน้อยตามธรรมชาติของข้อมูล

## Wyckoff Signal (Spring / Upthrust) — MT5 + TradingView

`Wyckoff_Signal.mq5` และ `Wyckoff_Signal.pine` แปลงหลักการ Wyckoff เป็น
สัญญาณ Buy/Sell แบบ No-Repaint โดยเลือกเฉพาะเหตุการณ์ที่ **นิยามเป็นกฎได้ชัด**
และเทรดได้จริง

**ตรรกะ**

1. **Trading Range** — หา high สูงสุด / low ต่ำสุดจาก **N แท่งก่อนหน้า**
   (ไม่รวมแท่งปัจจุบัน) เป็นกรอบแนวรับ-แนวต้าน
2. **Spring → BUY** — แท่งแทงหลุด **ใต้ low ของกรอบ** แต่ **ปิดกลับเข้ามาในกรอบ**
   = เบรกหลอกลง (failed breakdown) แรงขายหมด → กลับตัวขึ้น
3. **Upthrust/UTAD → SELL** — แท่งแทงทะลุ **เหนือ high ของกรอบ** แต่ **ปิดกลับใต้กรอบ**
   = เบรกหลอกขึ้น (failed breakout) แรงซื้อหมด → กลับตัวลง
4. **Effort vs Result (Volume)** — Spring/Upthrust ที่ดีมักมาพร้อม **วอลุ่มพุ่ง**
   ต้อง `volume ≥ ค่าเฉลี่ย × InpSpringVolMult` จึงยืนยัน
5. **SOS/SOW (option)** — เปิด `InpTradeBreakout` เพื่อจับ **เบรกจริงพร้อมวอลุ่มแรง**
   (SOS ปิดเหนือกรอบ = Buy ต่อเนื่อง, SOW ปิดใต้กรอบ = Sell ต่อเนื่อง)

**No-Repaint:** กรอบสร้างจากแท่ง**ก่อนหน้า**ล้วน ๆ และประเมินเฉพาะ**แท่งที่ปิดแล้ว**
(MT5 ข้ามแท่ง index 0 ที่กำลังวิ่ง / Pine ใช้ `[1]` + `offset = -1`) ลูกศรจึงไม่ขยับ

**พารามิเตอร์สำคัญ (MT5 / Pine)**

| MT5 | Pine | ค่าเริ่มต้น | ความหมาย |
|---|---|---|---|
| `InpRangeLookback` | `rangeLookback` | 20 | จำนวนแท่งที่ใช้สร้างกรอบ |
| `InpPenetrationPts` | `penTicks` | 0 | ระยะแทงหลุดขั้นต่ำ (points/ticks) |
| `InpRecoveryFrac` | `recoveryFrac` | 0 | ระยะดีดกลับเข้ากรอบขั้นต่ำ (% ของความสูงกรอบ) |
| `InpUseVolume` | `useVolume` | true | บังคับยืนยันด้วยวอลุ่ม |
| `InpVolMAPeriod` | `volMAPeriod` | 20 | คาบเฉลี่ยวอลุ่ม |
| `InpSpringVolMult` | `springVolMlt` | 1.5 | Spring/Upthrust ต้องวอลุ่ม ≥ เฉลี่ย × ค่านี้ |
| `InpTradeSpring` | `tradeSpring` | true | เปิดสัญญาณ Spring/Upthrust |
| `InpTradeBreakout` | `tradeBreakout` | false | เปิดสัญญาณ SOS/SOW (เบรกต่อเนื่อง) |

> **หมายเหตุเรื่องวอลุ่ม:** Forex บน MT5 เป็น **tick volume** (ไม่ใช่วอลุ่มจริง)
> ส่วน TradingView ใช้ volume ของแพลตฟอร์มเอง ผลจึงต่างกันได้ตามธรรมชาติของข้อมูล
> ถ้าเทรดหุ้น/ฟิวเจอร์สที่มี real volume ตั้ง `InpUseRealVolume = true` ใน MT5

**Buffer (MT5)**: 0 = Buy, 1 = Sell, 2 = Range High, 3 = Range Low

## Elliott Signal (Wave-3 Breakout) — MT5 + TradingView

`Elliott_Signal.mq5` และ `Elliott_Signal.pine` — Elliott Wave แบบ**นับอัตโนมัติเต็มรูป
มักจะ repaint** ตัวนี้จึงเลือกทำเฉพาะจุดเข้าที่ **ความน่าจะเป็นสูงสุดและ non-repaint**
คือ **จังหวะเบรกเข้าคลื่น 3**

**ตรรกะ**

1. **Swing Pivots** — หา pivot high/low แบบ fractal ที่ยืนยันหลังผ่านไป `Depth` แท่ง
   (pivot ที่ยืนยันแล้ว **ไม่ขยับอีก**)
2. **โครงคลื่น 1-2** — ใช้ pivot 3 จุดสลับกัน P0-P1-P2
   - **ขาขึ้น:** P0 (low) → P1 (high) → P2 (low)
   - ตรวจ **กฎเหล็กข้อ 1 ของ Elliott:** คลื่น 2 ห้ามลงต่ำกว่าจุดเริ่มคลื่น 1
     → ต้อง `P2 > P0` (และ `P2 < P1`)
3. **Trigger (BUY)** — เมื่อราคา **ปิดทะลุเหนือ P1** (ยอดคลื่น 1) = คลื่น 3 เริ่มวิ่ง
   ขาลงกลับด้าน (P0 high → P1 low → P2 high, ปิดหลุดใต้ P1 = SELL)
4. **เป้า Fibonacci** — คำนวณเป้าคลื่น 3 ที่ **1.618 เท่าของคลื่น 1** วัดจาก P2
   (MT5 แสดงในข้อความแจ้งเตือน / Pine วาดเป็น label บนกราฟ)

**No-Repaint:** ใช้ pivot ที่**ยืนยันแล้ว**เท่านั้น + ทริกเกอร์เป็นการ**ปิดทะลุ**บนแท่งปิด
จึงไม่ย้อนแก้ (แลกกับ **ดีเลย์ `Depth` แท่ง** ในการยืนยัน pivot ซึ่งเป็นราคาที่ต้องจ่ายเพื่อไม่ repaint)

**พารามิเตอร์สำคัญ (MT5 / Pine)**

| MT5 | Pine | ค่าเริ่มต้น | ความหมาย |
|---|---|---|---|
| `InpDepth` | `depth` | 5 | จำนวนแท่งสองข้างที่ใช้ยืนยัน pivot (มาก = swing ใหญ่ขึ้น, ดีเลย์มากขึ้น) |
| `InpMinSwingPts` | `minSwingTicks` | 0 | ขนาด swing ขั้นต่ำเทียบ pivot ก่อนหน้า (กรอง noise) |
| `InpMaxWave2Retr` | `maxWave2Retr` | 100 | คลื่น 2 ย่อได้ไม่เกิน % ของคลื่น 1 (<100 = เข้มขึ้น) |
| `InpWave3Ext` | `wave3Ext` | 1.618 | ตัวคูณ Fibonacci เป้าคลื่น 3 |

**Buffer (MT5)**: 0 = Buy, 1 = Sell, 2 = Pivot High marker, 3 = Pivot Low marker

> **ข้อจำกัดที่ต้องเข้าใจ:** นี่คือ Elliott แบบ "ช่วยจับจังหวะเข้า" ไม่ใช่การนับคลื่น
> 1-2-3-4-5 / A-B-C ครบทั้งชุด (ซึ่งมีทางเลือกการนับหลายแบบและ repaint โดยธรรมชาติ)
> โฟกัสที่จุดเข้าคลื่น 3 ที่ผ่านกฎข้อ 1 — เป็นจุดที่โค้ดตัดสินได้ชัดและเทรดได้จริง

## วิธีติดตั้ง (Wyckoff / Elliott)

- **MT5:** วาง `.mq5` ใน `MQL5/Indicators/` → คอมไพล์ (F7) → ลากลงกราฟ
  (สองตัวนี้ **ไม่ต้องพึ่ง VWAP.ex5** ทำงานอิสระ)
- **TradingView:** เปิด Pine Editor → วางเนื้อหา `.pine` → Save → Add to chart
  → ตั้ง Alert จากเงื่อนไข "Wyckoff Buy/Sell" หรือ "Elliott Buy/Sell"

## ข้อควรระวัง

- VWAP เดิมออกแบบสำหรับตลาดที่มี volume จริง (หุ้น/ฟิวเจอร์ส) การใช้กับ
  Forex อาศัย tick volume เป็นตัวแทน ซึ่งใช้ได้ดีในทางปฏิบัติแต่ไม่ใช่
  volume จริง
- ควรใช้ Anchor แบบ **Session** สำหรับ intraday และ **Week/Month**
  สำหรับ swing
- **Wyckoff/Elliott เป็นเครื่องมือช่วยตัดสินใจ** ไม่ใช่ระบบเทรดอัตโนมัติสำเร็จรูป
  ควรใช้คู่กับการบริหารความเสี่ยง (stop loss / position sizing) และยืนยันด้วย
  บริบทตลาดเสมอ — โดยเฉพาะควรทดสอบ backtest ก่อนใช้เงินจริง
