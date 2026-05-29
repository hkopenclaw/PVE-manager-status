#!/usr/bin/env bash

# version: 2023.9.5
#新增硬碟訊息的控制變數，如果你不想顯示硬碟訊息就設定為false
#NVME硬碟
sNVMEInfo=true
#固態和機械硬碟
sODisksInfo=true
#debug，顯示修改後的內容，用於除錯
dmode=false

#腳本路徑
sdir=$(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd)
cd "$sdir"

sname=$(basename "${BASH_SOURCE[0]}")
sap=$sdir/$sname
echo 腳本路徑："$sap"

#需要修改的檔案
np=/usr/share/perl5/PVE/API2/Nodes.pm
pvejs=/usr/share/pve-manager/js/pvemanagerlib.js
plibjs=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

if ! command -v sensors > /dev/null; then
	echo 你需要先安裝 lm-sensors 和 linux-cpupower，腳本嘗試給你自動安裝
	if apt update ; apt install -y lm-sensors; then 
		echo lm-sensors 安裝成功
		
		echo 嘗試繼續安裝linux-cpupower獲取功耗訊息
		if apt install -y linux-cpupower;then
			echo linux-cpupower安裝成功
		else
			echo -e "linux-cpupower安裝失敗，可能無法正常獲取功耗訊息，你可以使用\033[34mapt update ; apt install linux-cpupower && modprobe msr && echo msr > /etc/modules-load.d/turbostat-msr.conf && chmod +s /usr/sbin/turbostat && echo 成功！\033[0m 手動安裝"
		fi
	else
		echo 腳本自動安裝所需依賴失敗
		echo -e "請使用藍色命令：\033[34mapt update ; apt install -y lm-sensors linux-cpupower && chmod +s /usr/sbin/turbostat && echo 成功！ \033[0m 手動安裝後重新運行本腳本"
		echo 腳本退出
		exit 1
	fi
fi


#獲取版本號
pvever=$(pveversion | awk -F"/" '{print $2}')
echo "你的PVE版本號：$pvever"

restore() {
	[ -e $np.$pvever.bak ]     && mv $np.$pvever.bak $np
	[ -e $pvejs.$pvever.bak ]  && mv $pvejs.$pvever.bak $pvejs
	[ -e $plibjs.$pvever.bak ] && mv $plibjs.$pvever.bak $plibjs
}

fail() {
	echo "修改失敗，可能不兼容你的pve版本：$pvever，開始還原"
	restore
	echo 還原完成
	exit 1
}

#還原修改
case $1 in 
	restore)
		restore
		echo 已還原修改
		
		if [ "$2" != 'remod' ];then 
			echo -e "請重新整理瀏覽器快取：\033[31mShift+F5\033[0m"
			systemctl restart pveproxy
		else 
			echo -----
		fi
		
		exit 0
	;;
	remod)
		echo 強制重新修改
		echo -----------
		"$sap" restore remod > /dev/null 
		"$sap"
		exit 0
	;;
esac

#檢查是否已經修改過
[ $(grep 'modbyshowtempfreq' $np $pvejs $plibjs | wc -l) -eq 3 ]  && {
	echo -e "
已經修改過，請勿重複修改
如果沒有生效，或者頁面一直轉圈圈
請使用 \033[31mShift+F5\033[0m 重新整理瀏覽器快取
如果一直異常，請執行：\033[31m\"$sap\" restore\033[0m 命令，可以還原修改
如果想強制重新修改，請執行：\033[31m\"$sap\" remod\033[0m 命令，可以還原修改
"
	exit 1
}


contentfornp=/tmp/.contentfornp.tmp

[ -e /usr/sbin/turbostat ] && {
	modprobe msr
	chmod +s /usr/sbin/turbostat
}
echo msr > /etc/modules-load.d/turbostat-msr.conf

cat > $contentfornp << 'EOF'

#modbyshowtempfreq

$res->{thermalstate} = `sensors -A`;
$res->{cpuFreq} = `
	goverf=/sys/devices/system/cpu/cpufreq/policy0/scaling_governor
	maxf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_max_freq
	minf=/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_min_freq
	
	cat /proc/cpuinfo | grep -i  "cpu mhz"
	echo -n 'gov:'
	[ -f \$goverf ] && cat \$goverf || echo none
	echo -n 'min:'
	[ -f \$minf ] && cat \$minf || echo none
	echo -n 'max:'
	[ -f \$maxf ] && cat \$maxf || echo none
	echo -n 'pkgwatt:'
	[ -e /usr/sbin/turbostat ] && turbostat --quiet --cpu package --show "PkgWatt" -S sleep 0.25 2>&1 | tail -n1 

`;
EOF



contentforpvejs=/tmp/.contentforpvejs.tmp

cat > $contentforpvejs << 'EOF'
//modbyshowtempfreq
	{
		itemId: 'thermal',
		colspan: 2,
		printBar: false,
		title: gettext('溫度(°C)'),
		textField: 'thermalstate',
		renderer:function(value){
			//value進來的值是有換行符的
			console.log(value)
			let b = value.trim().split(/\s+(?=^\w+-)/m).sort();
			let c = b.map(function (v){
				// 風扇轉速數據，直接返回
				let fandata = v.match(/(?<=:\s+)[1-9]\d*(?=\s+RPM\s+)/ig)
				if ( fandata ) {
					return '風扇: ' + fandata.join(';')
				}
			
				let name = v.match(/^[^-]+/)[0].toUpperCase();
				
				let temp = v.match(/(?<=:\s+)[+-][\d.]+(?=.?°C)/g);
				// 某些沒有數據的傳感器,不是溫度的傳感器
				if ( temp ) {
					temp = temp.map(v => Number(v).toFixed(0))
					
					if (/coretemp/i.test(name)) {
						name = 'CPU';
						temp = temp[0] + ( temp.length > 1 ? ' ( ' +   temp.slice(1).join(' | ') + ' )' : '');
					} else {
						temp = temp[0];
					}
					
					let crit = v.match(/(?<=\bcrit\b[^+]+\+)\d+/);
					
					
					return name + ': ' + temp + ( crit? ` ,crit: ${crit[0]}` : '');
					
				} else {
					return 'null'
				}
				

			});
			console.log(c);
			// 排除null值的
			c=c.filter( v => ! /^null$/.test(v) )
			//console.log(c);
			//排序，把cpu溫度放最前
			let cpuIdx = c.findIndex(v => /CPU/i.test(v) );
			if (cpuIdx > 0) {
				c.unshift(c.splice(cpuIdx, 1)[0]);
			}
			
			console.log(c)
			c = c.join(' | ');
			return c;
		 }
	},
	{
		  itemId: 'cpumhz',
		  colspan: 2,
		  printBar: false,
		  title: gettext('CPU頻率(GHz)'),
		  textField: 'cpuFreq',
		  renderer:function(v){
			//return v;
			console.log(v);
			let m = v.match(/(?<=^cpu[^\d]+)\d+/img);
			let m2 = m.map( e => ( e / 1000 ).toFixed(1) );
			m2 = m2.join(' | ');
			
			let gov = v.match(/(?<=^gov:).+/im)[0].toUpperCase();
			
			let min = (v.match(/(?<=^min:).+/im)[0]);
			if ( min !== 'none' ) {
				min=(min/1000000).toFixed(1);
			}
			
			let max = (v.match(/(?<=^max:).+/im)[0])
			if ( max !== 'none' ) {
				max=(max/1000000).toFixed(1);
			}
			
			let watt= v.match(/(?<=^pkgwatt:)[\d.]+$/im);
			watt = watt? " | 功耗: " + (watt[0]/1).toFixed(1) + 'W' : '';
			
			return `${m2} | MAX: ${max} | MIN: ${min}${watt} | 調速器: ${gov}`
		 }
	},
EOF


#檢查nvme硬碟
echo 檢查系統中的NVME硬碟
nvi=0
if $sNVMEInfo;then
	for nvme in $(ls /dev/nvme[0-9] 2> /dev/null); do
		chmod +s /usr/sbin/smartctl

		cat >> $contentfornp << EOF
	\$res->{nvme$nvi} = \`smartctl $nvme -a -j\`;
EOF
		
		
		cat >> $contentforpvejs << EOF
		{
			  itemId: 'nvme${nvi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('NVME${nvi}'),
			  textField: 'nvme${nvi}',
			  renderer:function(value){
				//return value;
				try{
					let  v = JSON.parse(value);
					//名字
					let model = v.model_name;
					if (! model) {
						return '找不到硬碟，直通或已被取消掛載';
					}
					// 溫度
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | " + temp + '°C' : '' ;
					
					// 通電時間
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | 通電: " + pot + '時' + ( poth ? ',次: '+ poth : '' )) : '';
					
					// 讀寫
					let log = v.nvme_smart_health_information_log;
					let rw=''
					let health=''
					if (log) {
						let read = log.data_units_read;
						let write = log.data_units_written;
						read = read ? (log.data_units_read / 1956882).toFixed(1) + 'T' : '';
						write = write ? (log.data_units_written / 1956882).toFixed(1) + 'T' : '';
						if (read && write) {
							rw = ' | R/W: ' + read + '/' + write;
						}
						let pu = log.percentage_used;
						let me = log.media_errors;
						if ( pu !== undefined ) {
							health = ' | 健康: ' + ( 100 - pu ) + '%'
							if ( me !== undefined ) {
								health += ',0E: ' + me
							}
						}
					}

					// smart狀態
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? '正常' : '警告!');
					}
					
					
					let t = model  + temp + health + pot + rw + smart;
					//console.log(t);
					return t;
				}catch(e){
					return '無法獲得有效消息';
				};

			 }
		},
EOF
		let nvi++
	done
fi
echo "已新增 $nvi 個NVME硬碟"



#檢查機械硬碟
echo 檢查系統中的SATA固態和機械硬碟
sdi=0
if $sODisksInfo;then
	for sd in $(ls /dev/sd[a-z] 2> /dev/null);do
		chmod +s /usr/sbin/smartctl
		chmod +s /usr/sbin/hdparm
		#檢查是否是真的機械硬碟
		sdsn=$(awk -F '/' '{print $NF}' <<< $sd)
		sdcr=/sys/block/$sdsn/queue/rotational
		[ -f $sdcr ] || continue
		
		if [ "$(cat $sdcr)" = "0" ];then
			hddisk=false
			sdtype="固態硬碟$sdi"
		else
			hddisk=true
			sdtype="機械硬碟$sdi"
		fi
		
		#[] && 型條件判斷，嵌套的條件判斷的非 || 後面一定要寫動作，否則會穿透到上一層的非條件
		#機械/固態硬碟輸出訊息邏輯,
		#如果硬碟不存在就輸出空JSON

		cat >> $contentfornp << EOF
	\$res->{sd$sdi} = \`
		if [ -b $sd ];then
			if $hddisk && hdparm -C $sd | grep -iq 'standby';then
				echo '{"standy": true}'
			else
				smartctl $sd -a -j
			fi
		else
			echo '{}'
		fi
	\`;
EOF

		cat >> $contentforpvejs << EOF
		{
			  itemId: 'sd${sdi}0',
			  colspan: 2,
			  printBar: false,
			  title: gettext('${sdtype}'),
			  textField: 'sd${sdi}',
			  renderer:function(value){
				//return value;
				try{
					let  v = JSON.parse(value);
					console.log(v)
					if (v.standy === true) {
						return '休眠中'
					}
					
					//名字
					let model = v.model_name;
					if (! model) {
						return '找不到硬碟，直通或已被取消掛載';
					}
					// 溫度
					let temp = v.temperature?.current;
					temp = ( temp !== undefined ) ? " | 溫度: " + temp + '°C' : '' ;
					
					// 通電時間
					let pot = v.power_on_time?.hours;
					let poth = v.power_cycle_count;
					
					pot = ( pot !== undefined ) ? (" | 通電: " + pot + '時' + ( poth ? ',次: '+ poth : '' )) : '';
					
					// smart狀態
					let smart = v.smart_status?.passed;
					if (smart === undefined ) {
						smart = '';
					} else {
						smart = ' | SMART: ' + (smart ? '正常' : '警告!');
					}
					
					
					let t = model + temp  + pot + smart;
					//console.log(t);
					return t;
				}catch(e){
					return '無法獲得有效消息';
				};
			 }
		},
EOF
		let sdi++
	done
fi
echo "已新增 $sdi 個SATA固態和機械硬碟"

echo 開始修改nodes.pm檔案
if ! grep -q 'modbyshowtempfreq' $np ;then
	[ ! -e $np.$pvever.bak ] && cp $np $np.$pvever.bak
	
	if [ "$(sed -n "/PVE::pvecfg::version_text()/{=;p;q}" "$np")" ];then #確認修改點
		#r追加文本後面必須跟回車，否則r 後面的文字都會被當成檔案名，導致腳本出錯
		sed -i "/PVE::pvecfg::version_text()/{
			r $contentfornp
		}" $np
		$dmode && sed -n "/PVE::pvecfg::version_text()/,+5p" $np
	else
		echo '找不到nodes.pm檔案的修改點'
		
		fail
	fi
else
	echo 已經修改過
fi

echo 開始修改pvemanagerlib.js檔案
if ! grep -q 'modbyshowtempfreq' $pvejs ;then
	[ ! -e $pvejs.$pvever.bak ]  && cp $pvejs $pvejs.$pvever.bak
	
	if [ "$(sed -n '/pveversion/,+3{
			/},/{=;p;q}
		}' $pvejs)" ];then 
		
		sed -i "/pveversion/,+3{
			/},/r $contentforpvejs
		}" $pvejs
		
		$dmode && sed -n "/pveversion/,+8p" $pvejs
	else
		echo '找不到pvemanagerlib.js檔案的修改點'
		fail
	fi


	echo 修改頁面高度
	#統計加了幾條
	addRs=$(grep -c '\$res' $contentfornp)
	addHei=$(( 28 * addRs))
	$dmode && echo "新增了$addRs條內容,增加高度為:${addHei}px"


	#原高度300
	echo 修改左欄高度
	if [ "$(sed -n '/widget.pveNodeStatus/,+4{
			/height:/{=;p;q}
		}' $pvejs)" ]; then 
		
		#獲取原高度
		wph=$(sed -n -E "/widget\.pveNodeStatus/,+4{
			/height:/{s/[^0-9]*([0-9]+).*/\1/p;q}
		}" $pvejs)
		
		sed -i -E "/widget\.pveNodeStatus/,+4{
			/height:/{
				s#[0-9]+#$(( wph + addHei))#
			}
		}" $pvejs
		
		$dmode && sed -n '/widget.pveNodeStatus/,+4{
			/height/{
				p;q
			}
		}' $pvejs

		#修改右邊欄高度，讓它和左邊一樣高，雙欄的時候否則導致浮動出問題
		#原高度325
		echo 修改右欄高度和左欄一致，解決浮動錯位
		if [ "$(sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{=;p;q}
			}' $pvejs)" ]; then 
			#獲取原高度
			nph=$(sed -n -E '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{s/[^0-9]*([0-9]+).*/\1/p;q}
			}' "$pvejs")
			
			sed -i -E "/nodeStatus:\s*nodeStatus/,+10{
				/minHeight:/{
					s#[0-9]+#$(( nph + addHei - (nph - wph) ))#
				}
			}" $pvejs
			
			$dmode && sed -n '/nodeStatus:\s*nodeStatus/,+10{
				/minHeight/{
					p;q
				}
			}' $pvejs

		else
			echo 右邊欄高度找不到修改點，修改失敗
			
		fi

	else
		echo 找不到修改高度的修改點
		fail
	fi

else
	echo 已經修改過
fi


echo 溫度，頻率，硬碟訊息相關修改已完成
echo ------------------------
echo ------------------------
echo 開始修改proxmoxlib.js檔案
echo 去除訂閱彈窗

if ! grep -q 'modbyshowtempfreq' $plibjs ;then

	[ ! -e $plibjs.$pvever.bak ] && cp $plibjs $plibjs.$pvever.bak
	
	if [ "$(sed -n '/\/nodes\/localhost\/subscription/{=;p;q}' $plibjs)" ];then 
		sed -i '/\/nodes\/localhost\/subscription/,+10{
			/if/ {
				:loop; N;
				s/if\s*(.*)\s*{/if (false) {/;
				t done; b loop; :done;
				a //modbyshowtempfreq;
			}
		}' $plibjs
		
		$dmode && sed -n "/\/nodes\/localhost\/subscription/,+10p" $plibjs
	else 
		echo 找不到修改點，放棄修改這個
	fi
else
	echo 已經修改過
fi
echo -e "------------------------
修改完成
請重新整理瀏覽器快取：\033[31mShift+F5\033[0m
如果你看到主頁面提示連接錯誤或者沒看到溫度和頻率，請按：\033[31mShift+F5\033[0m，重新整理瀏覽器快取！
如果你對效果不滿意，請執行：\033[31m\"$sap\" restore\033[0m 命令，可以還原修改
"

systemctl restart pveproxy
