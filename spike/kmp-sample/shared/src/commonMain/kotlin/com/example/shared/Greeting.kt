package com.example.shared

import kotlinx.coroutines.delay

class Greeting {
    suspend fun greet(): String {
        delay(10)
        return "Hello from Kotlin"
    }
}
