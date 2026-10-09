package com.ynov.crudapi.dog;

import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

import java.net.URI;
import java.util.List;

@RestController
@RequestMapping("/api/v1/dogs")
public class DogController {

    private final DogRepository dogRepository;

    public DogController(DogRepository dogRepository) {
        this.dogRepository = dogRepository;
    }

    @GetMapping
    public List<Dog> findAll() {
        return dogRepository.findAll();
    }

    @GetMapping("/{dogId}")
    public Dog findById(@PathVariable Long dogId) {
        return getOrThrow(dogId);
    }

    @PostMapping
    public ResponseEntity<Dog> create(@Valid @RequestBody Dog dog) {
        dog.setId(null);
        Dog saved = dogRepository.save(dog);
        return ResponseEntity.created(URI.create("/api/v1/dogs/" + saved.getId())).body(saved);
    }

    @PutMapping("/{dogId}")
    public Dog update(@PathVariable Long dogId, @Valid @RequestBody Dog dog) {
        Dog existing = getOrThrow(dogId);
        existing.setName(dog.getName());
        existing.setBreed(dog.getBreed());
        existing.setBirthDate(dog.getBirthDate());
        existing.setSterilized(dog.isSterilized());
        return dogRepository.save(existing);
    }

    @DeleteMapping("/{dogId}")
    public ResponseEntity<Void> delete(@PathVariable Long dogId) {
        dogRepository.delete(getOrThrow(dogId));
        return ResponseEntity.noContent().build();
    }

    private Dog getOrThrow(Long dogId) {
        return dogRepository.findById(dogId)
                .orElseThrow(() -> new ResponseStatusException(HttpStatus.NOT_FOUND, "Dog " + dogId + " not found"));
    }
}
