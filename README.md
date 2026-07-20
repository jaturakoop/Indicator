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

## ข้อควรระวัง

- VWAP เดิมออกแบบสำหรับตลาดที่มี volume จริง (หุ้น/ฟิวเจอร์ส) การใช้กับ
  Forex อาศัย tick volume เป็นตัวแทน ซึ่งใช้ได้ดีในทางปฏิบัติแต่ไม่ใช่
  volume จริง
- ควรใช้ Anchor แบบ **Session** สำหรับ intraday และ **Week/Month**
  สำหรับ swing
