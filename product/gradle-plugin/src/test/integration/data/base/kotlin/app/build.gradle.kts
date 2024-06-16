plugins {
    id("com.android.application")
    id("com.chaquo.python")
}

android {
    namespace = "com.chaquo.python.test"
    compileSdk = 23

    defaultConfig {
        applicationId = "com.chaquo.python.test"
        minSdk = 21
        targetSdk = 23
        versionCode = 1
        versionName = "0.0.1"
        ndk {
            abiFilters += "x86"
        }
    }
}
