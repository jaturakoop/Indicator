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
3. **สัญญาณ** — ยิงลูกศรเมื่อ **เทรนด์ + momentum ตรงกัน** (edge trigger ยิงครั้งเดียวตอนเริ่ม align)
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

## ข้อควรระวัง

- VWAP เดิมออกแบบสำหรับตลาดที่มี volume จริง (หุ้น/ฟิวเจอร์ส) การใช้กับ
  Forex อาศัย tick volume เป็นตัวแทน ซึ่งใช้ได้ดีในทางปฏิบัติแต่ไม่ใช่
  volume จริง
- ควรใช้ Anchor แบบ **Session** สำหรับ intraday และ **Week/Month**
  สำหรับ swing
