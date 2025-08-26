# Установка OpenWrt на Xiaomi Mi Router 4A 100M (R4AC intl v2)

## ⚠️ Важные предупреждения
- Всё, что вы делаете, вы делаете **на свой риск**. Возможен «кирпич».
- Обязательно имейте под рукой способ восстановить роутер через TFTP/miwifi recovery.
- Сделайте бэкап калибровочных данных Wi-Fi (раздел `ART`/`factory`) перед первой прошивкой.

---

## 1. Подготовка
- Скачайте утилиту [OpenWRTInvasion](https://github.com/acecilia/OpenWRTInvasion).
- Установите Python 3 и необходимые зависимости.
- Скачайте прошивку OpenWrt для вашей модели:
  - [Firmware Selector](https://firmware-selector.openwrt.org/)
  - Файл должен быть вида:
    ```
    openwrt-23.05.5-ramips-mt76x8-xiaomi_mi-router-4a-100m-intl-v2-squashfs-sysupgrade.bin
    ```

---

## Если DHCP не сработал
Иногда ПК получает адрес 169.254.x.x или вообще не получает IP. Это значит, что роутер не раздаёт DHCP.  
В таком случае нужно назначить статический IP вручную.

### macOS / Linux
1. Узнай интерфейс Ethernet:
   ```bash
   networksetup -listallhardwareports
   ```
   Обычно это `en0` или `enX`.

2. Задай статический IP:

   Для стоковой прошивки Xiaomi (OpenWRTInvasion):
   ```bash
   sudo ifconfig en0 inet 192.168.31.100 netmask 255.255.255.0 up
   ```
   → доступ к роутеру по `192.168.31.1`.

   Для OpenWrt:
   ```bash
   sudo ifconfig en0 inet 192.168.1.100 netmask 255.255.255.0 up
   ```
   → доступ к роутеру по `192.168.1.1`.

3. Проверка:
   ```bash
   ping 192.168.31.1   # для стока
   ping 192.168.1.1    # для OpenWrt
   ```

### Windows
1. Панель управления → Сеть и интернет → Центр управления сетями → Изменение параметров адаптера.  
2. Правый клик → «Свойства» → «Протокол Интернета TCP/IPv4».  
3. Установите вручную:
   - IP: `192.168.1.100` (или `192.168.31.100` для стока)  
   - Маска: `255.255.255.0`  
   - Шлюз: `192.168.1.1` (или `192.168.31.1`).

### Подсказка
- Если только что прошили → используйте `192.168.1.1` (OpenWrt).  
- Если ещё сток → используйте `192.168.31.1`.  
- Если recovery → задайте `192.168.31.100` на ПК, роутер ждёт TFTP на `192.168.31.1`.

---

## 2. Получение root-доступа (OpenWRTInvasion)
1. Подключите ПК к LAN-порту роутера.
2. Запустите OpenWRTInvasion:
   ```bash
   python3 remote_command_execution_vulnerability.py 192.168.31.1
   ```
3. В логах появится информация о доступе:
   ```
   * telnet 192.168.31.1
   * ssh root@192.168.31.1 (user: root, password: root)
   * ftp root@192.168.31.1
   ```

---

## 3. Передача прошивки
Так как `scp` недоступен, используйте один из способов:

### Вариант A: FTP
Подключитесь через FTP-клиент (например Cyberduck) к `192.168.31.1`, login/pass: `root/root`.  
Залейте файл прошивки в `/tmp`.

### Вариант B: cat | ssh
На ПК:
```bash
cat "openwrt-ramips-mt76x8-xiaomi_mi-router-4a-100m-intl-v2-squashfs-sysupgrade.bin" \
  | ssh -oKexAlgorithms=+diffie-hellman-group1-sha1 \
       -oHostKeyAlgorithms=+ssh-rsa \
       -c 3des-cbc \
       root@192.168.31.1 "cat > /tmp/firmware.bin"
```

---

## 4. Прошивка
На роутере:
```sh
cat /proc/mtd    # посмотреть имя раздела (обычно firmware или OS1)
mtd -r write /tmp/firmware.bin firmware
```
После перезагрузки устройство загрузится в OpenWrt (IP: `192.168.1.1`).

---

## 5. Подключение к OpenWrt
По умолчанию:
```bash
ssh root@192.168.1.1
```
- Пароль отсутствует.  
- После входа задайте новый:
  ```sh
  passwd
  ```

---

## 6. Failsafe mode (сейф-мод)
Если вы ошиблись с настройкой и потеряли доступ:
1. Перезагрузите роутер.  
2. Во время старта быстро многократно жмите кнопку **Reset**.  
3. Роутер загрузится в **failsafe** (мигающий LED).  
4. Подключитесь:
   ```bash
   telnet 192.168.1.1
   or
   ssh root@192.168.1.1
   ```
   (доступ без пароля).  
5. В этом режиме можно загрузить прошивку через `cat|ssh` и прошить заново.

---

## 7. Recovery (TFTP/miwifi)
Если роутер «окирпичился»:
1. Задайте на ПК IP `192.168.31.100/24`.  
2. Поднимите TFTP-сервер с прошивкой (файл должен называться строго `miwifi.bin`).  
3. Зажмите Reset и включите питание. Держите кнопку до мигания.  
4. Роутер заберёт файл с TFTP и перепрошьётся.

---

## 8. Настройка Wi-Fi
Пример для WPA2-PSK:
```sh
uci set wireless.radio0.disabled='0'
uci set wireless.default_radio0.ssid='MyWiFi_2G'
uci set wireless.default_radio0.encryption='psk2'
uci set wireless.default_radio0.key='MyPassword'

uci set wireless.radio1.disabled='0'
uci set wireless.default_radio1.ssid='MyWiFi_5G'
uci set wireless.default_radio1.encryption='psk2'
uci set wireless.default_radio1.key='MyPassword'

uci commit wireless
wifi reload
```

---

## 9. Установка LuCI (веб-интерфейс)
В **snapshot**-сборках LuCI отсутствует.  
Исправление:
1. Подключите роутер к интернету (WAN).  
2. Установите LuCI:
   ```sh
   opkg update
   opkg install luci
   /etc/init.d/uhttpd enable
   /etc/init.d/uhttpd start
   ```
3. В браузере откройте: [http://192.168.1.1](http://192.168.1.1).

Если в snapshot нет нужных пакетов → используйте **стабильный релиз (например 23.05.5)**, где LuCI идёт в образе.

---

## 10. Полезные команды
- Перезапуск Wi-Fi:
  ```sh
  wifi
  ```
- Проверка состояния:
  ```sh
  logread -f
  dmesg
  ```

---

## Итог
Теперь у вас:
- OpenWrt на Xiaomi Router 4A 100M intl v2  
- Рабочий SSH-доступ  
- Возможность заходить в failsafe/recovery  
- WPA2 Wi-Fi  
- LuCI (если ставить релиз или руками через opkg)

