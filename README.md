# WaterWall Proto51 v2 — تانل دوم (کنار v1)

نسخهٔ **دوم** همان اسکریپت `waterwall-proto51` — **بدون UDP** — برای اجرای **هم‌زمان** با تانل اول، بدون تداخل.

| | **v1 (تانل اول)** | **v2 (تانل دوم)** |
|---|-------------------|-------------------|
| نصب | `ww51` / `waterwall-proto51` | `ww51v2` / `waterwall-proto51-v2` |
| مسیر | `/opt/waterwall-proto51` | `/opt/waterwall-proto51-v2` |
| اینترفیس | `wtun0` | `wtun2` |
| subnet | `10.10.0.0/24` (peer `10.10.0.2`) | `10.10.1.0/24` (peer `10.10.1.2`) |
| PORT_OFFSET (encrypt) | `10000` | `10000` |
| پورت‌های پیش‌فرض ایران | `443 2053 2083 2087 2096 8443` | `443 2053 2083 2087 2096 8443` |
| salt رمزنگاری | `waterwall-proto51` | `waterwall-proto51-v2` |

v2 **هرگز** سرویس/کانفیگ v1 را stop یا overwrite نمی‌کند.

## نصب

روی **هر دو سرور** (اول خارج، بعد ایران):

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51-v2/master/install.sh -o /tmp/ww51v2-install.sh
sudo bash /tmp/ww51v2-install.sh
```

یا:

```bash
curl -fsSL https://raw.githubusercontent.com/khodehamed/waterwall-proto51-v2/master/install.sh | sudo bash
```

بعد از نصب:

```bash
sudo ww51v2          # منو
sudo ww51v2 status   # وضعیت
sudo ww51v2 edit     # ویرایش IP / PROTO / پورت‌ها
```

## نکات مهم

1. **تانل اول (v1) را نگه دار** — v2 جدا نصب می‌شود.
2. **PROTO** روی ایران و خارج v2 باید **یکسان** باشد (مثل v1).
3. **پورت‌های PUBLIC** مثل v1 هستند؛ اگر v1 و v2 روی **همان سرور ایران** باشند تداخل می‌گیرند (اسکریپت هشدار می‌دهد). از **سرور ایران دیگر** به همان خارج OK است.
4. اگر v1 رمزنگاری دارد، v2 می‌تواند جدا encrypt=0 یا y با کلید/offset خودش باشد.
5. backhaul و سایر تانل‌ها دست‌نخورده می‌مانند.

## منو

همان گزینه‌های v1: Install، Status، Restart، Edit، Change ports، Logs، Uninstall.

## حذف فقط v2

```bash
sudo ww51v2
# گزینه 7) Uninstall
```

v1 (`ww51`) همچنان باقی می‌ماند.

## لینک v1

تانل اول: [waterwall-proto51](https://github.com/khodehamed/waterwall-proto51)
