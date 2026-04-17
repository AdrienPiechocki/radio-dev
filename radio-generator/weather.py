import requests
from dataclasses import dataclass
from typing import List, Optional


# =========================
# MODELES (Dataclasses)
# =========================

@dataclass
class CurrentWeather:
    temperature: float
    windspeed: float
    winddirection: int
    weathercode: int
    time: str


@dataclass
class DailyForecast:
    date: str
    temp_max: float
    temp_min: float
    precipitation_sum: float
    wind_speed_max: float
    wind_direction: int
    weathercode: int
    sunrise: str
    sunset: str


@dataclass
class WeatherResult:
    city: str
    country: str
    latitude: float
    longitude: float
    current: CurrentWeather
    forecast: List[DailyForecast]


# =========================
# CLIENT API
# =========================

class OpenMeteoClient:
    GEO_URL = "https://geocoding-api.open-meteo.com/v1/search"
    WEATHER_URL = "https://api.open-meteo.com/v1/forecast"

    def get_coordinates(self, city: str, country: Optional[str] = None):
        params = {
            "name": city,
            "count": 5,
            "language": "fr",
            "format": "json"
        }

        response = requests.get(self.GEO_URL, params=params)
        response.raise_for_status()
        data = response.json()

        if "results" not in data:
            raise ValueError(f"Ville non trouvée : {city}")

        results = data["results"]

        # Gestion des villes homonymes
        if country:
            results = [r for r in results if r.get("country", "").lower() == country.lower()]
            if not results:
                raise ValueError(f"Aucune correspondance pour {city} en {country}")

        best = results[0]

        return {
            "name": best["name"],
            "country": best["country"],
            "latitude": best["latitude"],
            "longitude": best["longitude"]
        }

    def get_weather(self, latitude: float, longitude: float):
        params = {
            "latitude": latitude,
            "longitude": longitude,
            "current_weather": True,
            "daily": (
                "temperature_2m_max,"
                "temperature_2m_min,"
                "precipitation_sum,"
                "wind_speed_10m_max,"
                "wind_direction_10m_dominant,"
                "weathercode,"
                "sunrise,"
                "sunset"
            ),
            "timezone": "auto"
        }

        response = requests.get(self.WEATHER_URL, params=params)
        response.raise_for_status()
        return response.json()

    def get_weather_by_city(self, city: str, country: Optional[str] = None) -> WeatherResult:
        location = self.get_coordinates(city, country)
        weather_data = self.get_weather(location["latitude"], location["longitude"])

        # Current weather
        current_data = weather_data["current_weather"]
        current = CurrentWeather(
            temperature=current_data["temperature"],
            windspeed=current_data["windspeed"],
            winddirection=current_data["winddirection"],
            weathercode=current_data["weathercode"],
            time=current_data["time"]
        )

        # Daily forecast (7 jours)
        daily = weather_data["daily"]
        forecast = [
            DailyForecast(
                date=daily["time"][i],
                temp_max=daily["temperature_2m_max"][i],
                temp_min=daily["temperature_2m_min"][i],
                precipitation_sum=daily["precipitation_sum"][i],
                wind_speed_max=daily["wind_speed_10m_max"][i],
                wind_direction=daily["wind_direction_10m_dominant"][i],
                weathercode=daily["weathercode"][i],
                sunrise=daily["sunrise"][i],
                sunset=daily["sunset"][i],
            )
            for i in range(len(daily["time"]))
        ]

        return WeatherResult(
            city=location["name"],
            country=location["country"],
            latitude=location["latitude"],
            longitude=location["longitude"],
            current=current,
            forecast=forecast
        )


# =========================
# UTILISATION
# =========================

if __name__ == "__main__":
    client = OpenMeteoClient()

    weather = client.get_weather_by_city("Paris", country="France")

    print(weather)