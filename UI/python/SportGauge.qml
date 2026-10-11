import QtQuick

Item {
    id: gauge
    width: 500; height: 480
    property real value: 0
    property real minimum: 0
    property real maximum: 100
    property string caption: "SENSOR"
    property string unit: "%"
    property bool signedValue: false
    property bool live: true
    property bool showTarget: false
    property real targetValue: 0
    onTargetValueChanged: face.requestPaint()
    property color accent: "#69d4ff"
    property real displayed: value
    property real readoutX: signedValue ? 287 : 213
    Behavior on displayed { NumberAnimation { duration: 110 } }
    onDisplayedChanged: face.requestPaint()
    onLiveChanged: face.requestPaint()
    Canvas {
        id: face
        anchors.fill: parent
        onPaint: {
            var c=getContext('2d'); c.reset()
            function X(x) { return gauge.signedValue ? 500-x : x }
            function curve(rx,ry,start,end,color,width) {
                c.beginPath()
                for(var k=0;k<=120;k++) {
                    var a=(start+(end-start)*k/120)*Math.PI/180
                    var x=X(265+rx*Math.cos(a)), y=237+ry*Math.sin(a)
                    if(k===0)c.moveTo(x,y);else c.lineTo(x,y)
                }
                c.strokeStyle=color; c.lineWidth=width; c.stroke()
            }
            // Sculpted binnacle: elliptical outside, tapered metallic inside edge.
            c.beginPath(); c.moveTo(X(425),20); c.lineTo(X(266),26)
            c.bezierCurveTo(X(114),26,X(20),117,X(20),237)
            c.bezierCurveTo(X(20),359,X(123),451,X(265),451)
            c.lineTo(X(330),451); c.bezierCurveTo(X(371),436,X(372),404,X(379),366)
            c.lineTo(X(441),48); c.quadraticCurveTo(X(445),20,X(425),20)
            var panel=c.createLinearGradient(X(25),0,X(445),0)
            panel.addColorStop(0,'#101219'); panel.addColorStop(0.6,'#05070b'); panel.addColorStop(0.94,'#141b26'); panel.addColorStop(1,'#626d7a')
            c.fillStyle=panel; c.fill(); c.strokeStyle='#414751'; c.lineWidth=1; c.stroke()
            curve(244,212,90,270,'#555b66',1)
            curve(235,202,90,270,'#a5a8ae',1.3)
            // Layered light: warm gold with a restrained redline near full scale.
            curve(225,193,90,270,'#081522',20)   // Outer glow
            curve(225,193,90,270,'#102c43',10)
            curve(225,193,90,270,'#245575',5)
            curve(225,193,90,270,'#78c4ef',2)    // Main curve
            curve(225,193,245,270,'#b7e4ff',2)   // End cap
            curve(218,185,90,270,'#192c3b',1)
            var steps=gauge.signedValue?60:50, majorEvery=gauge.signedValue?10:5
            for(var i=0;i<=steps;i++) {
                var a=(90+180*i/steps)*Math.PI/180, major=i%majorEvery===0
                c.beginPath(); c.moveTo(X(265+232*Math.cos(a)),237+199*Math.sin(a))
                c.lineTo(X(265+(major?219:225)*Math.cos(a)),237+(major?187:193)*Math.sin(a))
                c.strokeStyle=major?'#dceefa':'#658aa3'; c.lineWidth=major?1.5:0.8; c.stroke()
            }
            if(gauge.live && gauge.showTarget) {
                var targetFraction=Math.max(0,Math.min(1,(gauge.targetValue-gauge.minimum)/(gauge.maximum-gauge.minimum)))
                var targetAngle=(90+180*targetFraction)*Math.PI/180
                c.beginPath()
                c.moveTo(X(265+240*Math.cos(targetAngle)),237+207*Math.sin(targetAngle))
                c.lineTo(X(265+213*Math.cos(targetAngle)),237+180*Math.sin(targetAngle))
                c.strokeStyle='#ffc078'; c.lineWidth=3; c.stroke()
            }
            if(gauge.live) {
                var fraction=(gauge.displayed-gauge.minimum)/(gauge.maximum-gauge.minimum)
                var degrees=90+180*fraction, a=degrees*Math.PI/180
                curve(225,193,Math.max(90,degrees-10),Math.min(270,degrees+10),'#a5deff',4)
                c.beginPath()
                c.moveTo(X(265+234*Math.cos(a)),237+202*Math.sin(a))
                c.lineTo(X(265+193*Math.cos(a-0.023)),237+164*Math.sin(a-0.023))
                c.lineTo(X(265+193*Math.cos(a+0.023)),237+164*Math.sin(a+0.023))
                c.closePath(); c.fillStyle='#f0f8ff'; c.fill()
            }
            // Secondary segmented load scale on the inboard edge.
            var load=gauge.signedValue?Math.abs(gauge.value)/90:gauge.value/100
            for(var s=0;s<18;s++) {
                var bx=X(386-s*1.3)
                c.fillStyle=gauge.live && load>(17-s)/18 ? (s<3?'#b7e4ff':'#78c4ef'):'#34363b'
                c.fillRect(bx,106+s*10,6,7)
            }
        }
    }
    Repeater {
        model: gauge.signedValue?7:11
        Text {
            required property int index
            property real fraction: index/(gauge.signedValue?6:10)
            property real a: (90+fraction*180)*Math.PI/180
            property real px: 265+190*Math.cos(a)
            property int number: Math.round(gauge.minimum+(gauge.maximum-gauge.minimum)*fraction)
            x: (gauge.signedValue?500-px:px)-width/2
            y: 237+162*Math.sin(a)-height/2
            text: (gauge.signedValue && number>0?'+':'')+number
            color: index===(gauge.signedValue?6:10)?'#a5deff':'#d5d7df'
            font { family: 'Rajdhani'; pixelSize: 25; weight: Font.Medium; italic: true }
        }
    }
    Text { x: gauge.readoutX-width/2; y: 159; text: gauge.caption; color: '#a4acba'; font { family: 'Rajdhani'; pixelSize: 13; letterSpacing: 2; weight: Font.DemiBold } }
    Text {
        x: gauge.readoutX-width/2; y: 175
        text: gauge.live ? (gauge.signedValue && gauge.value>0?'+':'')+(gauge.signedValue?gauge.value.toFixed(1):Math.round(gauge.value)) : '--'
        color: '#f6f7fc'; font { family: 'Rajdhani'; pixelSize: gauge.signedValue?89:113; weight: Font.DemiBold; italic: true; letterSpacing: -2 }
    }
    Text { x: gauge.readoutX-width/2; y: 290; text: gauge.unit; color: '#939baa'; font { family: 'Rajdhani'; pixelSize: 15; letterSpacing: 1 } }
    Text { visible: false; x: gauge.readoutX-width/2; y: 313; text: gauge.live ? 'TARGET '+Math.round(gauge.targetValue)+' %' : 'TARGET --'; color: '#ffc078'; font { family: 'Rajdhani'; pixelSize: 13; bold: true } }
    Image { x: gauge.readoutX-18; y: 333; width: 36; height: 36; source: gauge.signedValue?'assets/steering.svg':'assets/sensor.svg'; opacity: 0.8; rotation: gauge.signedValue && gauge.live ? gauge.value : 0; Behavior on rotation { NumberAnimation { duration: 110 } } }
}

