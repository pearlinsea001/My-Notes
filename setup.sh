#!/usr/bin/env bash
set -e
mkdir -p /tmp/_fv_keep
cp lib/main.dart pubspec.yaml /tmp/_fv_keep/
flutter create --org com.example --project-name filevault --platforms android .
cp /tmp/_fv_keep/main.dart lib/main.dart
cp /tmp/_fv_keep/pubspec.yaml pubspec.yaml

# ---- Android manifest: app name, storage flag, file provider, share-to-app, image cropper ----
python3 - <<'PY'
import re
m = 'android/app/src/main/AndroidManifest.xml'
s = open(m).read()

# App name shown under the launcher icon
s = re.sub(r'android:label="[^"]*"', 'android:label="My Notes"', s, count=1)

if 'requestLegacyExternalStorage' not in s:
    s = s.replace('<application',
        '<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="28"/>\n    <application android:requestLegacyExternalStorage="true"', 1)

if 'android.intent.action.SEND' not in s:
    filters = """
            <intent-filter>
                <action android:name="android.intent.action.SEND"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND_MULTIPLE"/>
                <category android:name="android.intent.category.DEFAULT"/>
                <data android:mimeType="*/*"/>
            </intent-filter>
        """
    s = s.replace('</activity>', filters + '</activity>', 1)

if 'vaultprovider' not in s:
    provider = """
        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.vaultprovider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/vault_paths"/>
        </provider>
    """
    s = s.replace('</application>', provider + '</application>', 1)

# Crop screen (image_cropper / uCrop)
if 'UCropActivity' not in s:
    crop = """
        <activity
            android:name="com.yalantis.ucrop.UCropActivity"
            android:screenOrientation="portrait"
            android:theme="@style/Theme.AppCompat.Light.NoActionBar"/>
    """
    s = s.replace('</application>', crop + '</application>', 1)

# Lets the app find a camera app on Android 11+
if 'IMAGE_CAPTURE' not in s:
    s = s.replace('</manifest>',
        '    <queries>\n        <intent>\n            <action android:name="android.media.action.IMAGE_CAPTURE"/>\n        </intent>\n    </queries>\n</manifest>', 1)

open(m, 'w').write(s)
PY

mkdir -p android/app/src/main/res/xml
cat > android/app/src/main/res/xml/vault_paths.xml <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <root-path name="root" path="" />
</paths>
XML

# ---- Native Android code (open with / share / receive shared files) ----
KT=$(find android/app/src/main -name MainActivity.kt | head -1)
PKG_LINE=$(grep -m1 '^package' "$KT")
{
echo "$PKG_LINE"
cat <<'KOTLIN'

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.CopyOnWriteArrayList

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val pending = CopyOnWriteArrayList<Map<String, String>>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
        channel?.invokeMethod("shared", null)
    }

    @Suppress("DEPRECATION")
    private fun handleIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val uris = ArrayList<Uri>()
        if (action == Intent.ACTION_SEND) {
            val u = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            if (u != null) uris.add(u)
        } else {
            val l = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            if (l != null) uris.addAll(l)
        }
        if (uris.isNotEmpty()) {
            for (u in uris) pending.add(describe(u))
        } else {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT)
            if (text != null) {
                pending.add(mapOf(
                    "kind" to "text",
                    "text" to text,
                    "subject" to (intent.getStringExtra(Intent.EXTRA_SUBJECT) ?: "")
                ))
            }
        }
        intent.action = Intent.ACTION_MAIN
    }

    private fun describe(uri: Uri): Map<String, String> {
        var name: String? = null
        try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) name = c.getString(idx)
                }
            }
        } catch (e: Exception) {
        }
        val mime = contentResolver.getType(uri) ?: ""
        var n = name ?: uri.lastPathSegment ?: "shared_file"
        if (!n.contains('.')) {
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
            if (ext != null) n = "$n.$ext"
        }
        return mapOf("kind" to "file", "uri" to uri.toString(), "name" to n, "mime" to mime)
    }

    private fun mimeOf(f: File): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase()) ?: "*/*"

    private fun uriFor(f: File): Uri =
        FileProvider.getUriForFile(this, "$packageName.vaultprovider", f)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "filevault/native")
        channel!!.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "takeShared" -> {
                        val list = ArrayList(pending)
                        pending.clear()
                        result.success(list)
                    }
                    "openWith" -> {
                        val f = File(call.argument<String>("path")!!)
                        val uri = uriFor(f)
                        val i = Intent(Intent.ACTION_VIEW)
                        i.setDataAndType(uri, mimeOf(f))
                        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        i.clipData = ClipData.newRawUri("", uri)
                        startActivity(Intent.createChooser(i, "Open with"))
                        result.success(null)
                    }
                    "shareFiles" -> {
                        val paths = call.argument<List<String>>("paths")!!
                        val uris = ArrayList<Uri>()
                        for (p in paths) uris.add(uriFor(File(p)))
                        val i: Intent
                        if (uris.size == 1) {
                            i = Intent(Intent.ACTION_SEND)
                            i.type = mimeOf(File(paths[0]))
                            i.putExtra(Intent.EXTRA_STREAM, uris[0])
                        } else {
                            i = Intent(Intent.ACTION_SEND_MULTIPLE)
                            i.type = "*/*"
                            i.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                        }
                        i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        val cd = ClipData.newRawUri("", uris[0])
                        for (k in 1 until uris.size) cd.addItem(ClipData.Item(uris[k]))
                        i.clipData = cd
                        startActivity(Intent.createChooser(i, "Share"))
                        result.success(null)
                    }
                    "shareText" -> {
                        val i = Intent(Intent.ACTION_SEND)
                        i.type = "text/plain"
                        i.putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "")
                        i.putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: "")
                        startActivity(Intent.createChooser(i, "Share"))
                        result.success(null)
                    }
                    "copyUri" -> {
                        val uri = Uri.parse(call.argument<String>("uri")!!)
                        val dest = call.argument<String>("dest")!!
                        Thread {
                            try {
                                val input = contentResolver.openInputStream(uri)
                                    ?: throw Exception("Cannot read shared file")
                                input.use { i ->
                                    File(dest).outputStream().use { o -> i.copyTo(o) }
                                }
                                val len = File(dest).length()
                                runOnUiThread { result.success(len) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("copy", e.message, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("native", e.message, null)
            }
        }
    }
}
KOTLIN
} > "$KT"

# ---- Make every plugin compile against Android 36 ----
if [ -f android/build.gradle.kts ]; then
cat >> android/build.gradle.kts <<'EOF'

subprojects {
    val fixSdk: () -> Unit = {
        project.extensions.findByName("android")?.withGroovyBuilder {
            "compileSdkVersion"(36)
        }
        Unit
    }
    if (state.executed) fixSdk() else afterEvaluate { fixSdk() }
}
EOF
elif [ -f android/build.gradle ]; then
cat >> android/build.gradle <<'EOF'

subprojects {
    def fixSdk = { p ->
        if (p.hasProperty('android')) {
            p.android.compileSdkVersion 36
        }
    }
    if (project.state.executed) { fixSdk(project) } else { afterEvaluate { fixSdk(it) } }
}
EOF
fi

flutter pub get
